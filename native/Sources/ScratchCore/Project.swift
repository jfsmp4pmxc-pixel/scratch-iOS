import Foundation

// MARK: - Block

public enum BlockInput {
    case literal(ScratchValue)
    case block(String)
    case variable(id: String, name: String)
    case list(id: String, name: String)
    case broadcast(String)
    case empty
}

public final class Block {
    public let id: String
    public let opcode: String
    public var next: String?
    public var parent: String?
    public var inputs: [String: BlockInput] = [:]
    public var fields: [String: ScratchValue] = [:]
    public var fieldIds: [String: String] = [:]
    public var topLevel: Bool = false
    public var shadow: Bool = false
    public var x: Double = 0
    public var y: Double = 0
    /// Mã kiểu của literal (4 số, 9 màu, 10 chuỗi...) để ghi lại đúng khi lưu.
    public var inputTypes: [String: Int] = [:]
    public var mutation: [String: String] = [:]

    public init(id: String, opcode: String) {
        self.id = id
        self.opcode = opcode
    }

    static func parse(id: String, json: [String: Any]) -> Block? {
        guard let opcode = json["opcode"] as? String else { return nil }
        let b = Block(id: id, opcode: opcode)
        b.next = json["next"] as? String
        b.parent = json["parent"] as? String
        b.topLevel = (json["topLevel"] as? Bool) ?? false
        b.shadow = (json["shadow"] as? Bool) ?? false
        b.x = (json["x"] as? NSNumber)?.doubleValue ?? 0
        b.y = (json["y"] as? NSNumber)?.doubleValue ?? 0

        if let inputs = json["inputs"] as? [String: Any] {
            for (k, v) in inputs {
                b.inputs[k] = parseInput(v)
                if let ty = primType(v) { b.inputTypes[k] = ty }
            }
        }
        if let fields = json["fields"] as? [String: Any] {
            for (k, v) in fields {
                if let arr = v as? [Any], arr.count >= 1 {
                    b.fields[k] = ScratchValue.from(json: arr[0])
                    if arr.count >= 2, let fid = arr[1] as? String { b.fieldIds[k] = fid }
                }
            }
        }
        if let m = json["mutation"] as? [String: Any] {
            for (k, v) in m {
                if let s = v as? String { b.mutation[k] = s }
                else if let n = v as? NSNumber { b.mutation[k] = n.stringValue }
            }
        }
        return b
    }

    private static func parseInput(_ any: Any) -> BlockInput {
        guard let arr = any as? [Any], arr.count >= 2 else { return .empty }
        let payload = arr[1]
        if let id = payload as? String { return .block(id) }
        if let prim = payload as? [Any], prim.count >= 2 {
            let type = (prim[0] as? NSNumber)?.intValue ?? 0
            switch type {
            case 11:
                return .broadcast(ScratchValue.from(json: prim[1]).asString)
            case 12:
                let name = ScratchValue.from(json: prim[1]).asString
                let vid = prim.count > 2 ? ScratchValue.from(json: prim[2]).asString : name
                return .variable(id: vid, name: name)
            case 13:
                let name = ScratchValue.from(json: prim[1]).asString
                let lid = prim.count > 2 ? ScratchValue.from(json: prim[2]).asString : name
                return .list(id: lid, name: name)
            default:
                return .literal(ScratchValue.from(json: prim[1]))
            }
        }
        return .empty
    }

    private static func primType(_ any: Any) -> Int? {
        guard let arr = any as? [Any], arr.count >= 2, let prim = arr[1] as? [Any], prim.count >= 2 else { return nil }
        return (prim[0] as? NSNumber)?.intValue
    }

    /// Chuyển lại thành JSON của project.json.
    func jsonObject(blocks: [String: Block]) -> [String: Any] {
        var d: [String: Any] = [
            "opcode": opcode,
            "next": next ?? NSNull(),
            "parent": parent ?? NSNull(),
            "shadow": shadow,
            "topLevel": topLevel
        ]
        if topLevel { d["x"] = x; d["y"] = y }

        var ins: [String: Any] = [:]
        for (k, v) in inputs {
            switch v {
            case .empty:
                break
            case .literal(let val):
                let prim: [Any] = [inputTypes[k] ?? 10, val.asString]
                ins[k] = [1, prim] as [Any]
            case .broadcast(let n):
                let prim: [Any] = [11, n, n]
                ins[k] = [1, prim] as [Any]
            case .variable(let id, let name):
                let prim: [Any] = [12, name, id]
                let sh: [Any] = [10, ""]
                ins[k] = [3, prim, sh] as [Any]
            case .list(let id, let name):
                let prim: [Any] = [13, name, id]
                let sh: [Any] = [10, ""]
                ins[k] = [3, prim, sh] as [Any]
            case .block(let cid):
                let child = blocks[cid]
                if child?.shadow == true {
                    ins[k] = [1, cid] as [Any]
                } else if k.hasPrefix("SUBSTACK") {
                    ins[k] = [2, cid] as [Any]
                } else if let c = child, BlockCatalog.spec(for: c.opcode)?.shape == .boolean {
                    ins[k] = [2, cid] as [Any]
                } else {
                    let sh: [Any] = [10, ""]
                    ins[k] = [3, cid, sh] as [Any]
                }
            }
        }
        d["inputs"] = ins

        var fs: [String: Any] = [:]
        for (k, v) in fields {
            let idValue: Any = fieldIds[k] ?? NSNull()
            fs[k] = [v.jsonObject, idValue] as [Any]
        }
        d["fields"] = fs

        if !mutation.isEmpty {
            var m: [String: Any] = ["tagName": "mutation", "children": [Any]()]
            for (k, v) in mutation { m[k] = v }
            d["mutation"] = m
        }
        return d
    }
}

// MARK: - Assets

public final class Costume {
    public var name: String
    public let assetId: String
    public let md5ext: String
    public let dataFormat: String
    public let bitmapResolution: Double
    public var rotationCenterX: Double
    public var rotationCenterY: Double

    init(json: [String: Any]) {
        name = (json["name"] as? String) ?? "costume"
        assetId = (json["assetId"] as? String) ?? ""
        dataFormat = (json["dataFormat"] as? String) ?? "png"
        md5ext = (json["md5ext"] as? String) ?? "\(assetId).\(dataFormat)"
        let res = (json["bitmapResolution"] as? NSNumber)?.doubleValue ?? 1
        bitmapResolution = res > 0 ? res : 1
        rotationCenterX = (json["rotationCenterX"] as? NSNumber)?.doubleValue ?? 0
        rotationCenterY = (json["rotationCenterY"] as? NSNumber)?.doubleValue ?? 0
    }

    public var isSVG: Bool { dataFormat.lowercased() == "svg" }

    func jsonObject() -> [String: Any] {
        return ["name": name, "assetId": assetId, "md5ext": md5ext, "dataFormat": dataFormat,
                "bitmapResolution": bitmapResolution,
                "rotationCenterX": rotationCenterX, "rotationCenterY": rotationCenterY]
    }
}

public final class Sound {
    public var name: String
    public let assetId: String
    public let md5ext: String
    public let dataFormat: String
    public let format: String
    public let rate: Double
    public let sampleCount: Int

    init(json: [String: Any]) {
        name = (json["name"] as? String) ?? "sound"
        assetId = (json["assetId"] as? String) ?? ""
        dataFormat = (json["dataFormat"] as? String) ?? "wav"
        md5ext = (json["md5ext"] as? String) ?? "\(assetId).\(dataFormat)"
        format = (json["format"] as? String) ?? ""
        rate = (json["rate"] as? NSNumber)?.doubleValue ?? 22050
        sampleCount = (json["sampleCount"] as? NSNumber)?.intValue ?? 0
    }

    func jsonObject() -> [String: Any] {
        return ["name": name, "assetId": assetId, "md5ext": md5ext, "dataFormat": dataFormat,
                "format": format, "rate": rate, "sampleCount": sampleCount]
    }
}

// MARK: - Variables

public final class Variable {
    public let id: String
    public var name: String
    public var value: ScratchValue
    public let isCloud: Bool
    init(id: String, name: String, value: ScratchValue, isCloud: Bool = false) {
        self.id = id; self.name = name; self.value = value; self.isCloud = isCloud
    }
}

public final class ListVariable {
    public let id: String
    public var name: String
    public var items: [ScratchValue]
    init(id: String, name: String, items: [ScratchValue]) {
        self.id = id; self.name = name; self.items = items
    }
}

public struct Monitor {
    public let id: String
    public var label: String
    public var variableId: String
    public var x: Double
    public var y: Double
    public var visible: Bool
}

// MARK: - Target

public enum RotationStyle: String {
    case allAround = "all around"
    case leftRight = "left-right"
    case none = "don't rotate"
}

public struct Bubble {
    public var text: String
    public var isThought: Bool
}

public struct PenState {
    public var isDown = false
    public var size: Double = 1
    public var hue: Double = 66.66     // 0...100
    public var saturation: Double = 100
    public var brightness: Double = 100
    public var transparency: Double = 0
}

public final class Target {
    public let isStage: Bool
    public var name: String
    public var variables: [String: Variable] = [:]
    public var lists: [String: ListVariable] = [:]
    public var blocks: [String: Block] = [:]
    public var costumes: [Costume] = []
    public var sounds: [Sound] = []
    public var currentCostume: Int = 0
    public var x: Double = 0
    public var y: Double = 0
    public var size: Double = 100
    public var direction: Double = 90
    public var visible: Bool = true
    public var draggable: Bool = false
    public var rotationStyle: RotationStyle = .allAround
    public var volume: Double = 100
    public var effects: [String: Double] = [:]
    public var bubble: Bubble?
    public var pen = PenState()

    public var isClone = false
    /// Đặt true khi khối bị sửa: lúc lưu sẽ ghi lại toàn bộ khối của target.
    public var blocksDirty = false
    /// Đặt true khi danh sách trang phục/âm thanh bị sửa.
    public var assetsDirty = false
    public weak var cloneParent: Target?
    /// Chỉ số của target trong mảng "targets" của project.json gốc (để lưu lại).
    var rawIndex: Int?
    /// opcode -> danh sách id block gốc (hat).
    var hatCache: [String: [String]] = [:]
    var procedureCache: [String: ProcedureInfo] = [:]

    init(isStage: Bool, name: String) {
        self.isStage = isStage
        self.name = name
    }

    public var costume: Costume? {
        guard !costumes.isEmpty else { return nil }
        let i = min(max(currentCostume, 0), costumes.count - 1)
        return costumes[i]
    }

    func baseJSON() -> [String: Any] {
        return [
            "isStage": isStage, "name": name,
            "variables": [String: Any](), "lists": [String: Any](), "broadcasts": [String: Any](),
            "blocks": [String: Any](), "comments": [String: Any](),
            "currentCostume": currentCostume,
            "costumes": costumes.map { $0.jsonObject() },
            "sounds": sounds.map { $0.jsonObject() },
            "volume": volume, "layerOrder": 1
        ]
    }

    func buildCaches() {
        hatCache.removeAll()
        procedureCache.removeAll()
        for (id, b) in blocks where b.topLevel {
            hatCache[b.opcode, default: []].append(id)
            if b.opcode == "procedures_definition",
               case .block(let protoId)? = b.inputs["custom_block"],
               let proto = blocks[protoId],
               let code = proto.mutation["proccode"] {
                let names = Target.parseJSONStringArray(proto.mutation["argumentnames"])
                let ids = Target.parseJSONStringArray(proto.mutation["argumentids"])
                let warp = (proto.mutation["warp"] ?? "false") == "true"
                procedureCache[code] = ProcedureInfo(definitionId: id, argNames: names, argIds: ids, warp: warp)
            }
        }
        // Giữ thứ tự ổn định để chạy script lặp lại được.
        for k in hatCache.keys { hatCache[k]?.sort() }
    }

    static func parseJSONStringArray(_ s: String?) -> [String] {
        guard let s = s, let data = s.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return arr.map { ScratchValue.from(json: $0).asString }
    }

    func lookupVariable(id: String?, name: String?, stage: Target?) -> Variable? {
        if let id = id {
            if let v = variables[id] { return v }
            if let v = stage?.variables[id] { return v }
        }
        if let name = name {
            if let v = variables.values.first(where: { $0.name == name }) { return v }
            if let v = stage?.variables.values.first(where: { $0.name == name }) { return v }
        }
        return nil
    }

    func lookupList(id: String?, name: String?, stage: Target?) -> ListVariable? {
        if let id = id {
            if let v = lists[id] { return v }
            if let v = stage?.lists[id] { return v }
        }
        if let name = name {
            if let v = lists.values.first(where: { $0.name == name }) { return v }
            if let v = stage?.lists.values.first(where: { $0.name == name }) { return v }
        }
        return nil
    }

    /// Tạo bản sao (clone) chia sẻ block/costume nhưng có trạng thái riêng.
    func makeClone() -> Target {
        let c = Target(isStage: false, name: name)
        c.isClone = true
        c.cloneParent = cloneParent ?? self
        for (k, v) in variables { c.variables[k] = Variable(id: v.id, name: v.name, value: v.value, isCloud: false) }
        for (k, v) in lists { c.lists[k] = ListVariable(id: v.id, name: v.name, items: v.items) }
        c.blocks = blocks
        c.costumes = costumes
        c.sounds = sounds
        c.currentCostume = currentCostume
        c.x = x; c.y = y; c.size = size; c.direction = direction
        c.visible = visible; c.draggable = draggable
        c.rotationStyle = rotationStyle
        c.volume = volume; c.effects = effects
        c.pen = pen
        c.hatCache = hatCache
        c.procedureCache = procedureCache
        return c
    }
}

struct ProcedureInfo {
    let definitionId: String
    let argNames: [String]
    let argIds: [String]
    let warp: Bool
}

// MARK: - Project

public enum ProjectError: Error, LocalizedError {
    case invalidArchive
    case missingProjectJSON
    case invalidProjectJSON
    case unsupportedCompression
    case oldFormat

    public var errorDescription: String? {
        switch self {
        case .invalidArchive: return "Tệp .sb3 không hợp lệ (không đọc được ZIP)."
        case .missingProjectJSON: return "Không tìm thấy project.json trong tệp."
        case .invalidProjectJSON: return "project.json bị lỗi."
        case .unsupportedCompression: return "Kiểu nén ZIP không được hỗ trợ."
        case .oldFormat: return "Chỉ hỗ trợ định dạng Scratch 3 (.sb3)."
        }
    }
}

public final class Project {
    public var targets: [Target] = []
    public var monitors: [Monitor] = []
    /// Dữ liệu tài nguyên (md5ext -> bytes).
    public var assets: [String: Data] = [:]
    var rawJSON: [String: Any] = [:]
    var rawMonitors: [[String: Any]] = []

    public var stage: Target { targets.first(where: { $0.isStage }) ?? targets[0] }

    public init() {}

    /// Tạo project từ project.json + tài nguyên.
    public init(projectJSON: Data, assets: [String: Data]) throws {
        guard let root = try? JSONSerialization.jsonObject(with: projectJSON) as? [String: Any] else {
            throw ProjectError.invalidProjectJSON
        }
        guard let targetsJSON = root["targets"] as? [[String: Any]] else {
            throw ProjectError.oldFormat
        }
        rawJSON = root
        self.assets = assets

        for (index, tj) in targetsJSON.enumerated() {
            let isStage = (tj["isStage"] as? Bool) ?? false
            let t = Target(isStage: isStage, name: (tj["name"] as? String) ?? (isStage ? "Stage" : "Sprite"))
            t.rawIndex = index

            if let vars = tj["variables"] as? [String: Any] {
                for (id, v) in vars {
                    guard let arr = v as? [Any], arr.count >= 2 else { continue }
                    let cloud = arr.count >= 3 && ((arr[2] as? Bool) ?? false)
                    t.variables[id] = Variable(id: id, name: ScratchValue.from(json: arr[0]).asString,
                                               value: ScratchValue.from(json: arr[1]), isCloud: cloud)
                }
            }
            if let lists = tj["lists"] as? [String: Any] {
                for (id, v) in lists {
                    guard let arr = v as? [Any], arr.count >= 2 else { continue }
                    let items = ((arr[1] as? [Any]) ?? []).map { ScratchValue.from(json: $0) }
                    t.lists[id] = ListVariable(id: id, name: ScratchValue.from(json: arr[0]).asString, items: items)
                }
            }
            if let blocks = tj["blocks"] as? [String: Any] {
                for (id, bj) in blocks {
                    if let d = bj as? [String: Any], let block = Block.parse(id: id, json: d) {
                        t.blocks[id] = block
                    }
                }
            }
            t.costumes = ((tj["costumes"] as? [[String: Any]]) ?? []).map { Costume(json: $0) }
            t.sounds = ((tj["sounds"] as? [[String: Any]]) ?? []).map { Sound(json: $0) }
            t.currentCostume = (tj["currentCostume"] as? NSNumber)?.intValue ?? 0
            t.volume = (tj["volume"] as? NSNumber)?.doubleValue ?? 100
            if !isStage {
                t.x = (tj["x"] as? NSNumber)?.doubleValue ?? 0
                t.y = (tj["y"] as? NSNumber)?.doubleValue ?? 0
                t.size = (tj["size"] as? NSNumber)?.doubleValue ?? 100
                t.direction = (tj["direction"] as? NSNumber)?.doubleValue ?? 90
                t.visible = (tj["visible"] as? Bool) ?? true
                t.draggable = (tj["draggable"] as? Bool) ?? false
                if let rs = tj["rotationStyle"] as? String, let style = RotationStyle(rawValue: rs) {
                    t.rotationStyle = style
                }
            }
            t.buildCaches()
            targets.append(t)
        }
        // Sắp xếp theo layerOrder (stage = 0 luôn ở dưới cùng).
        let order: [Int] = targetsJSON.map { ($0["layerOrder"] as? NSNumber)?.intValue ?? 0 }
        let indexed = targets.enumerated().sorted { order[$0.offset] < order[$1.offset] }
        targets = indexed.map { $0.element }
        if let si = targets.firstIndex(where: { $0.isStage }), si != 0 {
            let s = targets.remove(at: si)
            targets.insert(s, at: 0)
        }

        // Monitors: hiện hỗ trợ monitor biến.
        rawMonitors = (root["monitors"] as? [[String: Any]]) ?? []
        for m in rawMonitors {
            guard (m["opcode"] as? String) == "data_variable",
                  let id = m["id"] as? String else { continue }
            let params = (m["params"] as? [String: Any]) ?? [:]
            let name = (params["VARIABLE"] as? String) ?? id
            let sprite = m["spriteName"] as? String
            let label = sprite != nil ? "\(sprite!): \(name)" : name
            monitors.append(Monitor(id: id, label: label, variableId: id,
                                    x: (m["x"] as? NSNumber)?.doubleValue ?? 0,
                                    y: (m["y"] as? NSNumber)?.doubleValue ?? 0,
                                    visible: (m["visible"] as? Bool) ?? false))
        }
    }
}
