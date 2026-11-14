import Foundation

// MARK: - Khối tự định nghĩa (My Blocks)

extension BlockCatalog {

    /// Spec mặc định cho các opcode động, chỉ dùng để biết hình dạng khối.
    static let customFallback: [String: BlockSpec] = [
        "procedures_definition": BlockSpec(opcode: "procedures_definition", category: .custom, shape: .hat, segments: []),
        "procedures_call": BlockSpec(opcode: "procedures_call", category: .custom, shape: .stack, segments: []),
        "argument_reporter_string_number": BlockSpec(opcode: "argument_reporter_string_number", category: .custom, shape: .reporter, segments: []),
        "argument_reporter_boolean": BlockSpec(opcode: "argument_reporter_boolean", category: .custom, shape: .boolean, segments: [])
    ]

    /// Tách proccode ("bước %s %b") thành các đoạn chữ và ô nhập.
    public static func callSpec(proccode: String, argIds: [String]) -> BlockSpec {
        var segs: [Segment] = []
        var buf = ""
        var argIndex = 0
        let chars = Array(proccode)
        var i = 0

        func flush() {
            let t = buf.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { segs.append(.text(t)) }
            buf = ""
        }

        while i < chars.count {
            if chars[i] == "%", i + 1 < chars.count, "sbn".contains(chars[i + 1]) {
                flush()
                let kind: InputKind
                switch chars[i + 1] {
                case "b": kind = .boolean
                case "n": kind = .number
                default: kind = .text
                }
                let id = argIndex < argIds.count ? argIds[argIndex] : "arg\(argIndex)"
                argIndex += 1
                segs.append(.input(InputSpec(name: id, kind: kind, defaultValue: "")))
                i += 2
            } else {
                buf.append(chars[i])
                i += 1
            }
        }
        flush()
        return BlockSpec(opcode: "procedures_call", category: .custom, shape: .stack, segments: segs)
    }

    /// Spec của một khối cụ thể (xử lý khối động như procedures_call).
    public static func spec(for block: Block, in target: Target) -> BlockSpec? {
        switch block.opcode {
        case "procedures_call":
            let ids = Target.parseJSONStringArray(block.mutation["argumentids"])
            return callSpec(proccode: block.mutation["proccode"] ?? "", argIds: ids)
        case "procedures_definition":
            guard case .block(let pid)? = block.inputs["custom_block"], let proto = target.blocks[pid] else {
                return customFallback["procedures_definition"]
            }
            let names = Target.parseJSONStringArray(proto.mutation["argumentnames"])
            let call = callSpec(proccode: proto.mutation["proccode"] ?? "", argIds: names)
            var segs: [Segment] = [.text("định nghĩa")]
            var argIndex = 0
            for seg in call.segments {
                switch seg {
                case .input:
                    let n = argIndex < names.count ? names[argIndex] : "?"
                    argIndex += 1
                    segs.append(.text("(\(n))"))
                default:
                    segs.append(seg)
                }
            }
            return BlockSpec(opcode: "procedures_definition", category: .custom, shape: .hat, segments: segs)
        case "argument_reporter_string_number":
            return BlockSpec(opcode: block.opcode, category: .custom, shape: .reporter,
                             segments: [.text(block.fields["VALUE"]?.asString ?? "")])
        case "argument_reporter_boolean":
            return BlockSpec(opcode: block.opcode, category: .custom, shape: .boolean,
                             segments: [.text(block.fields["VALUE"]?.asString ?? "")])
        default:
            return spec(for: block.opcode)
        }
    }
}

public extension Target {

    static func jsonString(_ a: [String]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: a, options: []),
              let s = String(data: d, encoding: .utf8) else { return "[]" }
        return s
    }

    /// Mã (proccode) của các khối tự định nghĩa trong sprite này.
    var customBlockCodes: [String] { procedureCache.keys.sorted() }

    @discardableResult
    func makeArgumentReporter(name: String, isBoolean: Bool) -> Block {
        let b = Block(id: Target.newBlockID(), opcode: isBoolean ? "argument_reporter_boolean" : "argument_reporter_string_number")
        b.fields["VALUE"] = .string(name)
        blocks[b.id] = b
        return b
    }

    /// Tạo định nghĩa khối mới và đặt thành một script mới.
    @discardableResult
    func createProcedure(name: String, args: [(name: String, isBoolean: Bool)], warp: Bool) -> Block {
        let defId = Target.newBlockID()
        let protoId = Target.newBlockID()
        let proto = Block(id: protoId, opcode: "procedures_prototype")
        proto.shadow = true
        proto.parent = defId

        var code = name.replacingOccurrences(of: "%", with: "")
        var ids: [String] = [], names: [String] = [], defaults: [String] = []
        for a in args {
            code += a.isBoolean ? " %b" : " %s"
            let aid = Target.newBlockID()
            ids.append(aid)
            names.append(a.name)
            defaults.append(a.isBoolean ? "false" : "")
            let rep = makeArgumentReporter(name: a.name, isBoolean: a.isBoolean)
            rep.shadow = true
            rep.parent = protoId
            proto.inputs[aid] = .block(rep.id)
        }
        proto.mutation = [
            "proccode": code,
            "argumentids": Target.jsonString(ids),
            "argumentnames": Target.jsonString(names),
            "argumentdefaults": Target.jsonString(defaults),
            "warp": warp ? "true" : "false"
        ]

        let def = Block(id: defId, opcode: "procedures_definition")
        def.inputs["custom_block"] = .block(protoId)
        blocks[protoId] = proto
        blocks[defId] = def
        addScript(defId)
        finishEdit()
        return def
    }

    /// Tạo khối gọi một khối tự định nghĩa (chưa gắn vào đâu).
    func makeCall(code: String) -> Block? {
        guard let info = procedureCache[code], let def = blocks[info.definitionId],
              case .block(let pid)? = def.inputs["custom_block"], let proto = blocks[pid] else { return nil }
        let b = Block(id: Target.newBlockID(), opcode: "procedures_call")
        b.mutation = [
            "proccode": code,
            "argumentids": proto.mutation["argumentids"] ?? "[]",
            "warp": proto.mutation["warp"] ?? "false"
        ]
        let ids = Target.parseJSONStringArray(proto.mutation["argumentids"])
        for seg in BlockCatalog.callSpec(proccode: code, argIds: ids).segments {
            if case .input(let i) = seg {
                if case .boolean = i.kind { continue }
                b.inputs[i.name] = .literal(.string(""))
                b.inputTypes[i.name] = 10
            }
        }
        blocks[b.id] = b
        return b
    }

    /// Các đối số khả dụng nếu khối này nằm trong một script định nghĩa.
    func argumentOptions(forScriptContaining id: String) -> [(name: String, isBoolean: Bool)] {
        let rootId = scriptRoot(of: id)
        guard let root = blocks[rootId], root.opcode == "procedures_definition",
              case .block(let pid)? = root.inputs["custom_block"], let proto = blocks[pid] else { return [] }
        let names = Target.parseJSONStringArray(proto.mutation["argumentnames"])
        let spec = BlockCatalog.callSpec(proccode: proto.mutation["proccode"] ?? "", argIds: names)
        var kinds: [Bool] = []
        for seg in spec.segments {
            if case .input(let i) = seg {
                if case .boolean = i.kind { kinds.append(true) } else { kinds.append(false) }
            }
        }
        var out: [(name: String, isBoolean: Bool)] = []
        for (i, n) in names.enumerated() { out.append((name: n, isBoolean: i < kinds.count ? kinds[i] : false)) }
        return out
    }

    // MARK: Trang phục / âm thanh

    func addCostume(_ c: Costume) {
        costumes.append(c)
        currentCostume = costumes.count - 1
        assetsDirty = true
    }

    func removeCostume(at i: Int) {
        guard costumes.count > 1, costumes.indices.contains(i) else { return }
        costumes.remove(at: i)
        if i < currentCostume { currentCostume -= 1 }
        currentCostume = min(max(0, currentCostume), costumes.count - 1)
        assetsDirty = true
    }

    func renameCostume(at i: Int, to name: String) {
        guard costumes.indices.contains(i) else { return }
        let others = costumes.enumerated().filter { $0.offset != i }.map { $0.element.name }
        costumes[i].name = uniqueName(name, among: others)
        assetsDirty = true
    }

    func addSound(_ s: Sound) {
        sounds.append(s)
        assetsDirty = true
    }

    func removeSound(at i: Int) {
        guard sounds.indices.contains(i) else { return }
        sounds.remove(at: i)
        assetsDirty = true
    }

    func renameSound(at i: Int, to name: String) {
        guard sounds.indices.contains(i) else { return }
        let others = sounds.enumerated().filter { $0.offset != i }.map { $0.element.name }
        sounds[i].name = uniqueName(name, among: others)
        assetsDirty = true
    }
}
