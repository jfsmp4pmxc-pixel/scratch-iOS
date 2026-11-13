import Foundation

// MARK: - Hooks cho tầng nền tảng (đồ hoạ, âm thanh, hỏi đáp)

public struct Rect {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
}

/// Truy vấn không gian (kích thước, va chạm) do lớp đồ hoạ cung cấp. Toạ độ sân khấu, trục y hướng lên.
public protocol SpatialProvider: AnyObject {
    func bounds(of target: Target) -> Rect?
    func touching(_ a: Target, _ b: Target) -> Bool
    func touching(_ target: Target, x: Double, y: Double) -> Bool
}

public protocol PenSurface: AnyObject {
    func clear()
    func line(fromX: Double, fromY: Double, toX: Double, toY: Double, pen: PenState)
    func stamp(_ target: Target)
}

public protocol SoundPlaying: AnyObject {
    func play(_ sound: Sound, volume: Double, completion: @escaping () -> Void)
    func stopAll()
}

// MARK: - Thread

struct GlideState {
    var start: Double
    var duration: Double
    var sx: Double, sy: Double, ex: Double, ey: Double
}

enum LoopKind {
    case none, forever, repeatN, until, whileLoop, forEach, procedure
}

struct Frame {
    var next: String?
    var start: String?
    var loop: LoopKind = .none
    var counter: Double = 0
    var limit: Double = 0
    var owner: String?
    var args: [String: ScratchValue]?
    var warp = false
}

final class ScriptThread {
    let target: Target
    let topBlock: String
    var stack: [Frame] = []
    var done = false
    var blocked = false
    var sleeping = false
    var waitUntil: Double?
    var broadcastWait: [ScriptThread] = []
    var glide: GlideState?
    var reentry: String?

    init(target: Target, topBlock: String, first: String?) {
        self.target = target
        self.topBlock = topBlock
        stack = [Frame(next: first, start: first)]
    }

    var isWarp: Bool { stack.contains(where: { $0.warp }) }
}

// MARK: - Runtime

public final class Runtime {
    public let project: Project
    /// Mảng target theo thứ tự vẽ: stage trước, sau đó từ sau ra trước.
    public private(set) var targets: [Target]
    public let stage: Target
    public var monitors: [Monitor]

    public weak var spatial: SpatialProvider?
    public weak var pen: PenSurface?
    public weak var soundPlayer: SoundPlaying?
    /// Hỏi người dùng (sensing_askandwait). Gọi completion khi có câu trả lời.
    public var askHandler: ((String, @escaping (String) -> Void) -> Void)?
    /// Được gọi khi có thay đổi cần vẽ lại.
    public var onRedraw: (() -> Void)?
    public var onRunningChanged: ((Bool) -> Void)?

    public internal(set) var answer: String = ""
    public private(set) var unsupportedOpcodes: Set<String> = []
    public var isRunning: Bool { !threads.isEmpty }

    // Input
    var keysDown: Set<String> = []
    public private(set) var mouseX: Double = 0
    public private(set) var mouseY: Double = 0
    public private(set) var mouseDown = false

    // Nội bộ
    var threads: [ScriptThread] = []
    var redrawRequested = false
    var timerStart: Double
    var greaterThanState: [String: Bool] = [:]
    var cloneCount = 0
    static let maxClones = 300
    var dragTarget: Target?
    var dragOffsetX = 0.0, dragOffsetY = 0.0
    var dragMoved = false
    var lastRunning = false
    public var now: () -> Double = { Date().timeIntervalSince1970 }

    public init(project: Project) {
        self.project = project
        self.targets = project.targets
        self.stage = project.stage
        self.monitors = project.monitors
        self.timerStart = Date().timeIntervalSince1970
    }

    // MARK: Điều khiển

    public func greenFlag() {
        stopAll()
        timerStart = now()
        greaterThanState.removeAll()
        startHats("event_whenflagclicked") { _, _ in true }
        notifyRunning()
    }

    public func stopAll() {
        threads.removeAll()
        soundPlayer?.stopAll()
        targets.removeAll(where: { $0.isClone })
        cloneCount = 0
        for t in targets { t.bubble = nil }
        dragTarget = nil
        notifyRunning()
        requestRedraw()
    }

    public func clearPen() { pen?.clear(); requestRedraw() }

    // MARK: Input

    public func setMouse(x: Double, y: Double) {
        mouseX = max(-240, min(240, x))
        mouseY = max(-180, min(180, y))
        if let d = dragTarget, mouseDown {
            dragMoved = true
            setXY(d, mouseX + dragOffsetX, mouseY + dragOffsetY)
        }
    }

    public func mousePressed(x: Double, y: Double) {
        setMouse(x: x, y: y)
        mouseDown = true
        dragMoved = false
        let hit = topTarget(atX: mouseX, y: mouseY)
        if let hit = hit, hit.draggable, !hit.isStage {
            dragTarget = hit
            dragOffsetX = hit.x - mouseX
            dragOffsetY = hit.y - mouseY
            moveToFront(hit)
        } else {
            fireClick(on: hit)
        }
    }

    public func mouseReleased() {
        mouseDown = false
        if let d = dragTarget {
            if !dragMoved { fireClick(on: d) }
            dragTarget = nil
        }
    }

    private func fireClick(on hit: Target?) {
        if let hit = hit, !hit.isStage {
            startHats("event_whenthisspriteclicked") { t, _ in t === hit }
        } else {
            startHats("event_whenstageclicked") { t, _ in t.isStage }
        }
        notifyRunning()
    }

    public func keyDown(_ key: String) {
        let k = key.lowercased()
        let isNew = !keysDown.contains(k)
        keysDown.insert(k)
        guard isNew else { return }
        startHats("event_whenkeypressed") { _, b in
            let opt = b.fields["KEY_OPTION"]?.asString.lowercased() ?? ""
            return opt == k || opt == "any"
        }
        notifyRunning()
    }

    public func keyUp(_ key: String) { keysDown.remove(key.lowercased()) }

    func topTarget(atX x: Double, y: Double) -> Target? {
        guard let spatial = spatial else { return nil }
        for t in targets.reversed() where !t.isStage && t.visible {
            if spatial.touching(t, x: x, y: y) { return t }
        }
        return stage
    }

    // MARK: Hat / thread

    @discardableResult
    func startHats(_ opcode: String, matching: (Target, Block) -> Bool) -> [ScriptThread] {
        var started: [ScriptThread] = []
        // Sprite phía trên chạy trước, giống Scratch.
        for target in targets.reversed() {
            guard let ids = target.hatCache[opcode] else { continue }
            for id in ids {
                guard let block = target.blocks[id], matching(target, block) else { continue }
                started.append(startThread(target: target, topBlock: id))
            }
        }
        return started
    }

    @discardableResult
    func startThread(target: Target, topBlock: String) -> ScriptThread {
        let first = target.blocks[topBlock]?.next
        if let existing = threads.first(where: { $0.target === target && $0.topBlock == topBlock && !$0.done }) {
            existing.stack = [Frame(next: first, start: first)]
            existing.waitUntil = nil
            existing.glide = nil
            existing.reentry = nil
            existing.blocked = false
            existing.broadcastWait = []
            return existing
        }
        let t = ScriptThread(target: target, topBlock: topBlock, first: first)
        threads.append(t)
        return t
    }

    func broadcast(_ name: String) -> [ScriptThread] {
        let lower = name.lowercased()
        return startHats("event_whenbroadcastreceived") { _, b in
            (b.fields["BROADCAST_OPTION"]?.asString.lowercased() ?? "") == lower
        }
    }

    func notifyRunning() {
        let r = isRunning
        if r != lastRunning {
            lastRunning = r
            onRunningChanged?(r)
        }
    }

    func requestRedraw() { redrawRequested = true }

    // MARK: Vòng lặp chính

    /// Gọi ~30 lần mỗi giây.
    public func step() {
        redrawRequested = false
        pollGreaterThanHats()

        let begin = now()
        let budget = 0.025
        repeat {
            var progressed = false
            var i = 0
            while i < threads.count {
                let t = threads[i]
                t.sleeping = false
                if !t.done { run(t) }
                if !t.sleeping && !t.done { progressed = true }
                i += 1
            }
            threads.removeAll(where: { $0.done })
            if !progressed { break }
        } while !threads.isEmpty && !redrawRequested && (now() - begin) < budget

        notifyRunning()
        onRedraw?()
    }

    private func pollGreaterThanHats() {
        for target in targets {
            guard let ids = target.hatCache["event_whengreaterthan"] else { continue }
            for id in ids {
                guard let b = target.blocks[id] else { continue }
                let key = "\(ObjectIdentifier(target).hashValue)-\(id)"
                let option = b.fields["WHENGREATERTHANMENU"]?.asString.uppercased() ?? "TIMER"
                let t = ScriptThread(target: target, topBlock: id, first: nil)
                let threshold = evalInput(b.inputs["VALUE"], t).asNumber
                let current: Double = option == "TIMER" ? (now() - timerStart) : 0
                let isOver = current > threshold
                let was = greaterThanState[key] ?? false
                greaterThanState[key] = isOver
                if isOver && !was { startThread(target: target, topBlock: id) }
            }
        }
    }

    // MARK: Thao tác trạng thái dùng chung

    func setXY(_ t: Target, _ nx: Double, _ ny: Double) {
        var x = nx, y = ny
        if !t.isStage {
            (x, y) = fenced(t, x, y)
            let ox = t.x, oy = t.y
            t.x = x; t.y = y
            if t.pen.isDown, let pen = pen, (ox != x || oy != y) {
                pen.line(fromX: ox, fromY: oy, toX: x, toY: y, pen: t.pen)
            }
            requestRedraw()
        }
    }

    private func fenced(_ t: Target, _ x: Double, _ y: Double) -> (Double, Double) {
        guard let b = spatial?.bounds(of: t) else { return (x, y) }
        // Giữ lại ít nhất `inset` px của sprite trong sân khấu.
        let inset = min(15, min(b.width, b.height) / 2)
        let dx = x - t.x, dy = y - t.y
        let left = b.minX + dx, right = b.maxX + dx
        let bottom = b.minY + dy, top = b.maxY + dy
        var ox = 0.0, oy = 0.0
        if right < -240 + inset { ox = -240 + inset - right }
        else if left > 240 - inset { ox = 240 - inset - left }
        if top < -180 + inset { oy = -180 + inset - top }
        else if bottom > 180 - inset { oy = 180 - inset - bottom }
        return (x + ox, y + oy)
    }

    func moveToFront(_ t: Target) {
        guard !t.isStage, let i = targets.firstIndex(where: { $0 === t }) else { return }
        targets.remove(at: i)
        targets.append(t)
        requestRedraw()
    }

    func moveToBack(_ t: Target) {
        guard !t.isStage, let i = targets.firstIndex(where: { $0 === t }) else { return }
        targets.remove(at: i)
        targets.insert(t, at: 1)
        requestRedraw()
    }

    func shiftLayer(_ t: Target, by delta: Int) {
        guard !t.isStage, let i = targets.firstIndex(where: { $0 === t }) else { return }
        targets.remove(at: i)
        let n = min(max(i + delta, 1), targets.count)
        targets.insert(t, at: n)
        requestRedraw()
    }

    func removeClone(_ t: Target) {
        guard t.isClone else { return }
        targets.removeAll(where: { $0 === t })
        for th in threads where th.target === t { th.done = true }
        cloneCount = max(0, cloneCount - 1)
        requestRedraw()
    }

    func createClone(of source: Target) {
        guard !source.isStage, cloneCount < Runtime.maxClones else { return }
        let c = source.makeClone()
        cloneCount += 1
        if let i = targets.firstIndex(where: { $0 === source }) {
            targets.insert(c, at: i)   // clone nằm ngay phía sau bản gốc
        } else {
            targets.append(c)
        }
        for id in c.hatCache["control_start_as_clone"] ?? [] {
            startThread(target: c, topBlock: id)
        }
        requestRedraw()
    }

    func noteUnsupported(_ opcode: String) {
        unsupportedOpcodes.insert(opcode)
    }

    func target(named name: String) -> Target? {
        return targets.first(where: { !$0.isStage && !$0.isClone && $0.name == name })
    }

    // MARK: Biến hiển thị

    public func value(of monitor: Monitor) -> String {
        for t in targets {
            if let v = t.variables[monitor.variableId] { return v.value.asString }
        }
        return ""
    }

    public func setMonitor(variableId: String, visible: Bool) {
        for i in 0..<monitors.count where monitors[i].variableId == variableId {
            monitors[i].visible = visible
        }
        requestRedraw()
    }

    /// Xuất project hiện tại thành dữ liệu .sb3.
    public func exportSB3() throws -> Data {
        return try project.exportSB3(runtimeTargets: targets, monitors: monitors)
    }
}
