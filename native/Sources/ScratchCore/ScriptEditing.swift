import Foundation

/// Các thao tác chỉnh sửa script trên một Target.
public extension Target {

    static func newBlockID() -> String {
        return String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20))
    }

    func finishEdit() {
        blocksDirty = true
        buildCaches()
    }

    // MARK: Tạo khối

    /// Tạo khối mới (kèm khối menu ẩn) nhưng chưa gắn vào đâu.
    @discardableResult
    func makeBlock(_ spec: BlockSpec, context: EditorContext) -> Block {
        let b = Block(id: Target.newBlockID(), opcode: spec.opcode)
        for seg in spec.segments {
            switch seg {
            case .text:
                break
            case .field(let f):
                let opts = context.options(f.source)
                var value = f.defaultValue
                var fid: String?
                if value.isEmpty {
                    if let first = opts.first { value = first.value; fid = first.id }
                } else if let match = opts.first(where: { $0.value == value }) {
                    fid = match.id
                }
                b.fields[f.name] = .string(value)
                if let fid = fid { b.fieldIds[f.name] = fid }
            case .input(let i):
                applyDefaultInput(b, i, context)
            }
        }
        blocks[b.id] = b
        return b
    }

    internal func applyDefaultInput(_ b: Block, _ i: InputSpec, _ context: EditorContext) {
        switch i.kind {
        case .number:
            b.inputs[i.name] = .literal(.string(i.defaultValue)); b.inputTypes[i.name] = 4
        case .text:
            b.inputs[i.name] = .literal(.string(i.defaultValue)); b.inputTypes[i.name] = 10
        case .color:
            b.inputs[i.name] = .literal(.string(i.defaultValue)); b.inputTypes[i.name] = 9
        case .boolean:
            b.inputs.removeValue(forKey: i.name)
        case .broadcast:
            let name = i.defaultValue.isEmpty ? (context.broadcasts.first ?? "message1") : i.defaultValue
            b.inputs[i.name] = .broadcast(name)
        case .menu(let op, let field, let source):
            let shadow = Block(id: Target.newBlockID(), opcode: op)
            shadow.shadow = true
            shadow.parent = b.id
            var v = i.defaultValue
            if v.isEmpty { v = context.options(source).first?.value ?? "" }
            shadow.fields[field] = .string(v)
            blocks[shadow.id] = shadow
            b.inputs[i.name] = .block(shadow.id)
        }
    }

    // MARK: Cấu trúc

    func lastBlock(in b: Block) -> Block {
        var cur = b
        var guardCount = 0
        while let n = cur.next, let nb = blocks[n], guardCount < 10000 { cur = nb; guardCount += 1 }
        return cur
    }

    func scriptRoots() -> [Block] {
        return blocks.values.filter { $0.topLevel && !$0.shadow }.sorted { ($0.y, $0.id) < ($1.y, $1.id) }
    }

    func scriptRoot(of id: String) -> String {
        var cur = id
        var guardCount = 0
        while let b = blocks[cur], let p = b.parent, blocks[p] != nil, guardCount < 10000 { cur = p; guardCount += 1 }
        return cur
    }

    /// Đặt khối thành một script mới ở cuối vùng làm việc.
    func addScript(_ id: String) {
        guard let b = blocks[id] else { return }
        let maxY = blocks.values.filter { $0.topLevel && $0.id != id }.map { $0.y }.max() ?? -100
        b.topLevel = true
        b.parent = nil
        b.x = 40
        b.y = maxY + 120
    }

    func insertBlock(_ id: String, after anchorId: String) {
        guard let c = blocks[id], let a = blocks[anchorId] else { return }
        let old = a.next.flatMap { blocks[$0] }
        a.next = c.id
        c.parent = a.id
        c.topLevel = false
        if let o = old {
            let tail = lastBlock(in: c)
            tail.next = o.id
            o.parent = tail.id
        }
    }

    func insertBlock(_ id: String, intoSubstackOf hostId: String, input: String) {
        guard let c = blocks[id], let h = blocks[hostId] else { return }
        var old: Block?
        if case .block(let oid)? = h.inputs[input] { old = blocks[oid] }
        h.inputs[input] = .block(c.id)
        c.parent = h.id
        c.topLevel = false
        if let o = old {
            let tail = lastBlock(in: c)
            tail.next = o.id
            o.parent = tail.id
        }
    }

    /// Tách một khối ra khỏi vị trí hiện tại (khối phía sau được nối lên).
    func detachBlock(_ id: String) {
        guard let b = blocks[id] else { return }
        let nxt = b.next.flatMap { blocks[$0] }
        if let pid = b.parent, let p = blocks[pid] {
            if p.next == id {
                p.next = nxt?.id
                nxt?.parent = p.id
            } else {
                for (k, v) in p.inputs {
                    if case .block(let cid) = v, cid == id {
                        if let n = nxt {
                            p.inputs[k] = .block(n.id)
                            n.parent = p.id
                        } else {
                            p.inputs.removeValue(forKey: k)
                        }
                    }
                }
            }
        } else if b.topLevel, let n = nxt {
            n.topLevel = true
            n.x = b.x
            n.y = b.y
            n.parent = nil
        }
        b.next = nil
        b.parent = nil
        b.topLevel = false
    }

    /// Tách một khối cùng toàn bộ các khối phía sau nó (giống khi kéo trong Scratch).
    func detachStack(_ id: String) {
        guard let b = blocks[id] else { return }
        if let pid = b.parent, let p = blocks[pid] {
            if p.next == id {
                p.next = nil
            } else {
                for (k, v) in p.inputs {
                    if case .block(let cid) = v, cid == id { p.inputs.removeValue(forKey: k) }
                }
            }
        }
        b.parent = nil
        b.topLevel = false
    }

    /// Các id thuộc về một chuỗi khối (kể cả khối con và khối giá trị).
    func collectStackIds(from id: String) -> Set<String> {
        var out = Set<String>()
        func walk(_ cur: String) {
            guard let b = blocks[cur], !out.contains(cur) else { return }
            out.insert(cur)
            for v in b.inputs.values {
                if case .block(let c) = v { walk(c) }
            }
            if let n = b.next { walk(n) }
        }
        walk(id)
        return out
    }

    func moveStack(_ id: String, afterBlock anchor: String) {
        guard id != anchor, !collectStackIds(from: id).contains(anchor) else { return }
        detachStack(id)
        insertBlock(id, after: anchor)
        finishEdit()
    }

    func moveStack(_ id: String, intoSubstackOf host: String, input: String) {
        guard id != host, !collectStackIds(from: id).contains(host) else { return }
        detachStack(id)
        insertBlock(id, intoSubstackOf: host, input: input)
        finishEdit()
    }

    func moveStackToNewScript(_ id: String) {
        detachStack(id)
        addScript(id)
        finishEdit()
    }

    func deleteSubtree(_ id: String, includingNext: Bool) {
        guard let b = blocks[id] else { return }
        for (_, v) in b.inputs {
            if case .block(let cid) = v { deleteSubtree(cid, includingNext: true) }
        }
        if includingNext, let n = b.next { deleteSubtree(n, includingNext: true) }
        blocks.removeValue(forKey: id)
    }

    /// Xoá một khối (cùng nội dung bên trong); các khối phía sau được nối lên.
    func removeBlock(_ id: String) {
        detachBlock(id)
        deleteSubtree(id, includingNext: false)
        finishEdit()
    }

    /// Xoá cả script chứa khối này.
    func removeScript(containing id: String) {
        let root = scriptRoot(of: id)
        deleteSubtree(root, includingNext: true)
        finishEdit()
    }

    @discardableResult
    func moveBlockUp(_ id: String) -> Bool {
        guard let b = blocks[id], let pid = b.parent, let p = blocks[pid], p.next == id else { return false }
        if let s = BlockCatalog.spec(for: b.opcode), s.shape == .hat || !s.hasNext { return false }
        if BlockCatalog.spec(for: p.opcode)?.shape == .hat { return false }

        detachBlock(id)
        if p.topLevel {
            b.topLevel = true
            b.x = p.x
            b.y = p.y
            b.next = p.id
            p.parent = b.id
            p.topLevel = false
        } else if let gid = p.parent, let g = blocks[gid] {
            if g.next == p.id {
                g.next = b.id
            } else {
                for (k, v) in g.inputs {
                    if case .block(let cid) = v, cid == p.id { g.inputs[k] = .block(b.id) }
                }
            }
            b.parent = g.id
            b.next = p.id
            p.parent = b.id
        }
        finishEdit()
        return true
    }

    @discardableResult
    func moveBlockDown(_ id: String) -> Bool {
        guard let b = blocks[id], let nid = b.next, let n = blocks[nid] else { return false }
        if let s = BlockCatalog.spec(for: n.opcode), !s.hasNext { return false }
        return moveBlockUp(nid)
    }

    // MARK: Ô nhập

    func setLiteral(block id: String, input: String, value: String) {
        guard let b = blocks[id] else { return }
        if case .block(let cid)? = b.inputs[input] { deleteSubtree(cid, includingNext: true) }
        b.inputs[input] = .literal(.string(value))
        if b.inputTypes[input] == nil || b.inputTypes[input] == 12 { b.inputTypes[input] = 10 }
        finishEdit()
    }

    func setInput(block id: String, input: String, reporter: Block) {
        guard let b = blocks[id] else { return }
        if case .block(let cid)? = b.inputs[input] { deleteSubtree(cid, includingNext: true) }
        b.inputs[input] = .block(reporter.id)
        reporter.parent = b.id
        reporter.topLevel = false
        finishEdit()
    }

    func resetInput(block id: String, input: InputSpec, context: EditorContext) {
        guard let b = blocks[id] else { return }
        if case .block(let cid)? = b.inputs[input.name] { deleteSubtree(cid, includingNext: true) }
        applyDefaultInput(b, input, context)
        finishEdit()
    }

    func setField(block id: String, field: String, option: MenuOption) {
        guard let b = blocks[id] else { return }
        b.fields[field] = .string(option.value)
        b.fieldIds[field] = option.id
        finishEdit()
    }

    func setBroadcast(block id: String, input: String, name: String) {
        guard let b = blocks[id] else { return }
        b.inputs[input] = .broadcast(name)
        finishEdit()
    }

    // MARK: Biến / danh sách

    @discardableResult
    func createVariable(named name: String, forAllSprites: Bool, stage: Target) -> Variable {
        let v = Variable(id: Target.newBlockID(), name: name, value: .number(0))
        let owner: Target = (forAllSprites || isStage) ? stage : self
        owner.variables[v.id] = v
        return v
    }

    @discardableResult
    func createList(named name: String, forAllSprites: Bool, stage: Target) -> ListVariable {
        let l = ListVariable(id: Target.newBlockID(), name: name, items: [])
        let owner: Target = (forAllSprites || isStage) ? stage : self
        owner.lists[l.id] = l
        return l
    }
}
