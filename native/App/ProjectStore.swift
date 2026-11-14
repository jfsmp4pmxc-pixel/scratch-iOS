import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import ScratchCore

extension UTType {
    /// Khai báo trong Info.plist (UTExportedTypeDeclarations).
    static let sb3 = UTType("com.scratchios.sb3") ?? UTType(filenameExtension: "sb3") ?? .data
}

struct SB3Document: FileDocument {
    static var readableContentTypes: [UTType] { [.sb3] }
    static var writableContentTypes: [UTType] { [.sb3] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct InputEditRequest: Identifiable {
    let id = UUID()
    let target: Target
    let blockId: String
    let input: InputSpec
}

enum NameKind { case variable, list, broadcast, rename }

struct NamePrompt: Identifiable {
    let id = UUID()
    let kind: NameKind
    let initial: String
    let onDone: (String, Bool) -> Void     // (tên, dùng cho mọi sprite)
}

struct AskRequest: Identifiable {
    let id = UUID()
    let question: String
    let completion: (String) -> Void
}

final class ProjectStore: ObservableObject {
    @Published var runtime: Runtime?
    @Published var renderer: StageRenderer?
    @Published var projectName = ""
    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var ask: AskRequest?
    @Published var unsupported: [String] = []
    @Published var statusMessage: String?

    // Trình chỉnh sửa
    @Published var selectedTarget: Target?
    @Published var selectedBlock: String?
    @Published var insertInside: String?          // tên ô SUBSTACK sẽ chèn vào, nil = chèn phía sau
    @Published var revision = 0
    @Published var showPalette = false
    @Published var inputEdit: InputEditRequest?
    @Published var namePrompt: NamePrompt?
    @Published var showCustomBlock = false
    @Published var editorTab = 0                  // 0 = Code, 1 = Trang phục, 2 = Âm thanh
    private var previewPlayer: AVAudioPlayer?

    private var audio: AudioPlayer?

    // MARK: Thư mục lưu dự án

    static var projectsDirectory: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func savedProjects() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: ProjectStore.projectsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "sb3" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    // MARK: Mở

    func open(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let project = try Project(sb3: data)
                let name = url.deletingPathExtension().lastPathComponent
                DispatchQueue.main.async { self.install(project, name: name) }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Không mở được “\(url.lastPathComponent)”: \(error.localizedDescription)"
                }
            }
        }
    }

    private func install(_ project: Project, name: String) {
        runtime?.stopAll()
        let rt = Runtime(project: project)
        let r = StageRenderer(runtime: rt)
        let player = AudioPlayer(project: project)
        rt.soundPlayer = player
        rt.askHandler = { [weak self] question, done in
            DispatchQueue.main.async { self?.ask = AskRequest(question: question, completion: done) }
        }
        rt.onRunningChanged = { [weak self] running in
            DispatchQueue.main.async { self?.isRunning = running }
        }
        audio = player
        renderer = r
        runtime = rt
        projectName = name
        isRunning = false
        unsupported = []
        ask = nil
        selectedBlock = nil
        insertInside = nil
        selectedTarget = rt.targets.first(where: { !$0.isStage && !$0.isClone }) ?? rt.stage
        revision += 1
    }

    func newProject() {
        install(Project.blank(), name: "Dự án mới")
    }

    // MARK: Sprite

    var sprites: [Target] { (runtime?.targets ?? []).filter { !$0.isClone } }

    func select(target t: Target) {
        selectedTarget = t
        selectedBlock = nil
        insertInside = nil
    }

    func addBlankSprite() {
        guard let rt = runtime else { return }
        let t = rt.project.makeBlankSprite(existingNames: rt.targets.map { $0.name })
        rt.addSprite(t)
        select(target: t)
        revision += 1
    }

    private func readImage(url: URL) -> (data: Data, format: String, cx: Double, cy: Double, res: Double)? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { errorMessage = "Không đọc được tệp ảnh."; return nil }
        var format = url.pathExtension.lowercased()
        if format == "jpeg" { format = "jpg" }
        if format == "svg" {
            guard let size = svgIntrinsicSize(data) else { errorMessage = "SVG không hợp lệ."; return nil }
            return (data, format, size.width / 2, size.height / 2, 1)
        }
        if format == "png" || format == "jpg" {
            guard let img = UIImage(data: data), let cg = img.cgImage else { errorMessage = "Ảnh không hợp lệ."; return nil }
            let w = Double(cg.width), h = Double(cg.height)
            return (data, format, w / 2, h / 2, max(1, (w / 150).rounded(.up)))
        }
        errorMessage = "Chỉ hỗ trợ ảnh PNG, JPG hoặc SVG."
        return nil
    }

    func importSprite(url: URL) {
        guard let rt = runtime, let img = readImage(url: url) else { return }
        let t = rt.project.makeSprite(name: url.deletingPathExtension().lastPathComponent,
                                      existingNames: rt.targets.map { $0.name }, assetData: img.data,
                                      dataFormat: img.format, centerX: img.cx, centerY: img.cy, bitmapResolution: img.res)
        rt.addSprite(t)
        select(target: t)
        revision += 1
    }

    // MARK: Trang phục & âm thanh

    func importCostume(url: URL) {
        guard let rt = runtime, let t = selectedTarget, let img = readImage(url: url) else { return }
        // Ảnh nhập vào trang phục giữ độ phân giải gốc nhưng không quá lớn so với sân khấu.
        let c = rt.project.makeCostume(name: url.deletingPathExtension().lastPathComponent,
                                       existing: t.costumes.map { $0.name }, data: img.data, format: img.format,
                                       centerX: img.cx, centerY: img.cy, bitmapResolution: img.res)
        t.addCostume(c)
        revision += 1
    }

    func addPaintedCostume(png: Data, pixelWidth: Double, pixelHeight: Double, resolution: Double) {
        guard let rt = runtime, let t = selectedTarget else { return }
        let c = rt.project.makeCostume(name: "vẽ", existing: t.costumes.map { $0.name }, data: png, format: "png",
                                       centerX: pixelWidth / 2, centerY: pixelHeight / 2, bitmapResolution: resolution)
        t.addCostume(c)
        revision += 1
    }

    func selectCostume(_ i: Int) {
        guard let t = selectedTarget, t.costumes.indices.contains(i) else { return }
        t.currentCostume = i
        t.assetsDirty = true
        revision += 1
    }

    func importSound(url: URL) {
        guard let rt = runtime, let t = selectedTarget else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        guard ext == "wav" || ext == "mp3" else { errorMessage = "Chỉ hỗ trợ âm thanh WAV hoặc MP3."; return }
        guard let data = try? Data(contentsOf: url) else { errorMessage = "Không đọc được tệp âm thanh."; return }
        var rate = 22050.0
        var count = 0
        if let f = try? AVAudioFile(forReading: url) {
            rate = f.processingFormat.sampleRate
            count = Int(f.length)
        }
        let name = url.deletingPathExtension().lastPathComponent
        let s = rt.project.makeSound(name: name, existing: t.sounds.map { $0.name }, data: data, format: ext,
                                     rate: rate, sampleCount: count)
        t.addSound(s)
        revision += 1
    }

    func previewSound(_ s: Sound) {
        guard let data = runtime?.project.assets[s.md5ext] else { return }
        previewPlayer?.stop()
        previewPlayer = try? AVAudioPlayer(data: data)
        previewPlayer?.play()
    }

    func deleteSprite(_ t: Target) {
        guard let rt = runtime, !t.isStage else { return }
        rt.removeSprite(t)
        if selectedTarget === t { selectedTarget = rt.targets.first(where: { !$0.isStage && !$0.isClone }) ?? rt.stage }
        selectedBlock = nil
        revision += 1
    }

    func renameSprite(_ t: Target, to name: String) {
        guard let rt = runtime, !t.isStage else { return }
        let others = rt.targets.filter { $0 !== t }.map { $0.name }
        var unique = name
        var n = 2
        while others.contains(unique) { unique = "\(name)\(n)"; n += 1 }
        t.name = unique
        revision += 1
    }

    // MARK: Chỉnh sửa khối

    func context(for t: Target) -> EditorContext? {
        guard let rt = runtime else { return nil }
        let real = rt.targets.filter { !$0.isClone }
        let names = real.filter { !$0.isStage }.map { $0.name }
        var b = Set(Project.usedBroadcastNames(in: real))
        for n in rt.project.declaredBroadcasts { b.insert(n) }
        if b.isEmpty { b.insert("message1") }
        return EditorContext(target: t, stage: rt.stage, spriteNames: names, broadcasts: b.sorted())
    }

    func selectBlock(_ id: String) {
        selectedBlock = id
        insertInside = nil
    }

    func insert(spec: BlockSpec) {
        guard let t = selectedTarget, let ctx = context(for: t) else { return }
        place(t.makeBlock(spec, context: ctx), spec: spec, in: t)
    }

    func insertCall(code: String) {
        guard let t = selectedTarget, let block = t.makeCall(code: code),
              let spec = BlockCatalog.spec(for: block, in: t) else { return }
        place(block, spec: spec, in: t)
    }

    func createProcedure(name: String, args: [(name: String, isBoolean: Bool)], warp: Bool) {
        guard let t = selectedTarget else { return }
        let def = t.createProcedure(name: name, args: args, warp: warp)
        selectedBlock = def.id
        insertInside = nil
        revision += 1
    }

    private func place(_ block: Block, spec: BlockSpec, in t: Target) {
        var placed = false
        if spec.shape != .hat, let selId = selectedBlock, let sel = t.blocks[selId], !sel.shadow {
            let selSpec = BlockCatalog.spec(for: sel, in: t)
            if let name = insertInside, selSpec?.substackNames.contains(name) == true {
                var hasChild = false
                if case .block? = sel.inputs[name] { hasChild = true }
                if spec.hasNext || !hasChild {
                    t.insertBlock(block.id, intoSubstackOf: sel.id, input: name)
                    placed = true
                }
            } else if selSpec?.hasNext ?? true {
                if spec.hasNext || sel.next == nil {
                    t.insertBlock(block.id, after: sel.id)
                    placed = true
                }
            }
        }
        if !placed {
            t.addScript(block.id)
            if spec.shape != .hat && selectedBlock != nil { statusMessage = "Khối này không chèn được ở đó, đã tạo script mới" }
        }
        t.finishEdit()
        selectedBlock = block.id
        insertInside = nil
        revision += 1
    }

    func deleteSelectedBlock() {
        guard let t = selectedTarget, let id = selectedBlock else { return }
        t.removeBlock(id)
        selectedBlock = nil
        insertInside = nil
        revision += 1
    }

    func deleteSelectedScript() {
        guard let t = selectedTarget, let id = selectedBlock else { return }
        t.removeScript(containing: id)
        selectedBlock = nil
        insertInside = nil
        revision += 1
    }

    func moveSelected(up: Bool) {
        guard let t = selectedTarget, let id = selectedBlock else { return }
        let ok = up ? t.moveBlockUp(id) : t.moveBlockDown(id)
        if !ok { statusMessage = "Không di chuyển được khối này" }
        revision += 1
    }

    func runSelectedScript() {
        guard let rt = runtime, let t = selectedTarget, let id = selectedBlock else { return }
        rt.runScript(of: t, rootId: t.scriptRoot(of: id))
    }

    // MARK: Lưu / xuất

    func exportData() -> Data? {
        guard let rt = runtime else { return nil }
        do { return try rt.exportSB3() }
        catch { errorMessage = "Không thể ghi dự án: \(error.localizedDescription)"; return nil }
    }

    /// Lưu vào thư mục Projects của ứng dụng.
    func saveToDocuments() {
        guard let data = exportData() else { return }
        let safe = projectName.isEmpty ? "Project" : projectName
        let url = ProjectStore.projectsDirectory.appendingPathComponent("\(safe).sb3")
        do {
            try data.write(to: url, options: .atomic)
            statusMessage = "Đã lưu “\(safe).sb3”"
        } catch {
            errorMessage = "Không thể lưu: \(error.localizedDescription)"
        }
    }

    func refreshDiagnostics() {
        let list = (runtime?.unsupportedOpcodes ?? []).sorted()
        if list != unsupported { unsupported = list }
    }
}
