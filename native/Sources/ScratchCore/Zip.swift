import Foundation
#if canImport(Compression)
import Compression
#endif

/// Đọc/ghi ZIP tối giản (đủ cho .sb3): đọc kiểu STORE và DEFLATE, ghi kiểu STORE.
public enum ZipArchive {

    // MARK: Read

    public static func read(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw ProjectError.invalidArchive }

        // Tìm End Of Central Directory (quét ngược).
        var eocd = -1
        var i = bytes.count - 22
        let limit = max(0, bytes.count - 22 - 65535)
        while i >= limit {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw ProjectError.invalidArchive }

        let entryCount = Int(u16(bytes, eocd + 10))
        var p = Int(u32(bytes, eocd + 16))
        var result: [String: Data] = [:]

        for _ in 0..<entryCount {
            guard p + 46 <= bytes.count, u32(bytes, p) == 0x02014b50 else { throw ProjectError.invalidArchive }
            let method = Int(u16(bytes, p + 10))
            let compSize = Int(u32(bytes, p + 20))
            let uncompSize = Int(u32(bytes, p + 24))
            let nameLen = Int(u16(bytes, p + 28))
            let extraLen = Int(u16(bytes, p + 30))
            let commentLen = Int(u16(bytes, p + 32))
            let localOffset = Int(u32(bytes, p + 42))
            guard p + 46 + nameLen <= bytes.count else { throw ProjectError.invalidArchive }
            let nameBytes = Array(bytes[(p + 46)..<(p + 46 + nameLen)])
            let name = String(decoding: nameBytes, as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen

            if name.hasSuffix("/") { continue }

            guard localOffset + 30 <= bytes.count, u32(bytes, localOffset) == 0x04034b50 else {
                throw ProjectError.invalidArchive
            }
            let lNameLen = Int(u16(bytes, localOffset + 26))
            let lExtraLen = Int(u16(bytes, localOffset + 28))
            let start = localOffset + 30 + lNameLen + lExtraLen
            guard start + compSize <= bytes.count else { throw ProjectError.invalidArchive }
            let raw = Data(bytes[start..<(start + compSize)])

            switch method {
            case 0:
                result[name] = raw
            case 8:
                guard let out = inflate(raw, expectedSize: uncompSize) else { throw ProjectError.invalidArchive }
                result[name] = out
            default:
                throw ProjectError.unsupportedCompression
            }
        }
        return result
    }

    private static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        if expectedSize == 0 { return Data() }
        #if canImport(Compression)
        var output = [UInt8](repeating: 0, count: expectedSize)
        let written: Int = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstBase, expectedSize, srcBase, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == expectedSize ? Data(output) : nil
        #else
        return nil
        #endif
    }

    // MARK: Write (STORE)

    public static func write(_ files: [(name: String, data: Data)]) -> Data {
        var out = [UInt8]()
        var central = [UInt8]()

        for file in files {
            let nameBytes = Array(file.name.utf8)
            let bytes = [UInt8](file.data)
            let crc = crc32(bytes)
            let offset = out.count

            // Local file header
            append32(&out, 0x04034b50)
            append16(&out, 20)          // version needed
            append16(&out, 0x0800)      // flags: UTF-8 names
            append16(&out, 0)           // method: store
            append16(&out, 0)           // time
            append16(&out, 0x21)        // date (1980-01-01)
            append32(&out, crc)
            append32(&out, UInt32(bytes.count))
            append32(&out, UInt32(bytes.count))
            append16(&out, UInt16(nameBytes.count))
            append16(&out, 0)
            out.append(contentsOf: nameBytes)
            out.append(contentsOf: bytes)

            // Central directory entry
            append32(&central, 0x02014b50)
            append16(&central, 20)
            append16(&central, 20)
            append16(&central, 0x0800)
            append16(&central, 0)
            append16(&central, 0)
            append16(&central, 0x21)
            append32(&central, crc)
            append32(&central, UInt32(bytes.count))
            append32(&central, UInt32(bytes.count))
            append16(&central, UInt16(nameBytes.count))
            append16(&central, 0)
            append16(&central, 0)
            append16(&central, 0)
            append16(&central, 0)
            append32(&central, 0)
            append32(&central, UInt32(offset))
            central.append(contentsOf: nameBytes)
        }

        let cdOffset = out.count
        out.append(contentsOf: central)
        append32(&out, 0x06054b50)
        append16(&out, 0)
        append16(&out, 0)
        append16(&out, UInt16(files.count))
        append16(&out, UInt16(files.count))
        append32(&out, UInt32(central.count))
        append32(&out, UInt32(cdOffset))
        append16(&out, 0)
        return Data(out)
    }

    // MARK: Helpers

    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 {
        return UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
    }

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        return UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    private static func append16(_ a: inout [UInt8], _ v: UInt16) {
        a.append(UInt8(v & 0xff)); a.append(UInt8(v >> 8))
    }

    private static func append32(_ a: inout [UInt8], _ v: UInt32) {
        a.append(UInt8(v & 0xff)); a.append(UInt8((v >> 8) & 0xff))
        a.append(UInt8((v >> 16) & 0xff)); a.append(UInt8((v >> 24) & 0xff))
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { n -> UInt32 in
            var c = UInt32(n)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
            return c
        }
    }()

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}

// MARK: - SB3

public extension Project {
    /// Mở tệp .sb3 (ZIP chứa project.json và các tài nguyên).
    convenience init(sb3 data: Data) throws {
        let files = try ZipArchive.read(data)
        guard let json = files["project.json"] else { throw ProjectError.missingProjectJSON }
        var assets = files
        assets.removeValue(forKey: "project.json")
        try self.init(projectJSON: json, assets: assets)
    }

    /// Ghi lại thành .sb3, cập nhật trạng thái hiện tại (vị trí, biến, khối, sprite...).
    func exportSB3(runtimeTargets: [Target]? = nil, monitors currentMonitors: [Monitor]? = nil) throws -> Data {
        var root = rawJSON
        let oldTargets = (root["targets"] as? [[String: Any]]) ?? []
        let source = (runtimeTargets ?? targets).filter { !$0.isClone }
        var out: [[String: Any]] = []
        var anyBlocksChanged = false

        for (order, t) in source.enumerated() {
            var tj: [String: Any]
            if let idx = t.rawIndex, idx < oldTargets.count { tj = oldTargets[idx] } else { tj = t.baseJSON() }
            tj["name"] = t.name
            tj["layerOrder"] = order
            tj["currentCostume"] = t.currentCostume
            tj["volume"] = t.volume
            if !t.isStage {
                tj["x"] = t.x; tj["y"] = t.y
                tj["size"] = t.size; tj["direction"] = t.direction
                tj["visible"] = t.visible
                tj["draggable"] = t.draggable
                tj["rotationStyle"] = t.rotationStyle.rawValue
            }
            var vars: [String: Any] = [:]
            let oldVars = (tj["variables"] as? [String: Any]) ?? [:]
            for (id, v) in t.variables {
                var arr: [Any] = [v.name, v.value.jsonObject]
                if let old = oldVars[id] as? [Any], old.count >= 3 { arr.append(old[2]) }
                vars[id] = arr
            }
            tj["variables"] = vars
            var lists: [String: Any] = [:]
            for (id, l) in t.lists { lists[id] = [l.name, l.items.map { $0.jsonObject }] as [Any] }
            tj["lists"] = lists

            if t.assetsDirty {
                tj["costumes"] = t.costumes.map { $0.jsonObject() }
                tj["sounds"] = t.sounds.map { $0.jsonObject() }
            }
            if t.blocksDirty || t.rawIndex == nil {
                var bj: [String: Any] = [:]
                for (id, b) in t.blocks { bj[id] = b.jsonObject(blocks: t.blocks) }
                tj["blocks"] = bj
                anyBlocksChanged = true
            }
            out.append(tj)
        }

        if anyBlocksChanged, let si = out.firstIndex(where: { ($0["isStage"] as? Bool) == true }) {
            var bc = (out[si]["broadcasts"] as? [String: Any]) ?? [:]
            let known = Set(bc.values.compactMap { $0 as? String })
            for name in Project.usedBroadcastNames(in: source) where !known.contains(name) { bc[name] = name }
            out[si]["broadcasts"] = bc
        }
        root["targets"] = out

        if let mons = currentMonitors, !rawMonitors.isEmpty {
            var outMon = rawMonitors
            for i in 0..<outMon.count {
                if let id = outMon[i]["id"] as? String, let m = mons.first(where: { $0.id == id }) {
                    outMon[i]["visible"] = m.visible
                }
            }
            root["monitors"] = outMon
        }

        let json = try JSONSerialization.data(withJSONObject: root, options: [])
        var files: [(name: String, data: Data)] = [("project.json", json)]
        for (name, data) in assets.sorted(by: { $0.key < $1.key }) { files.append((name, data)) }
        return ZipArchive.write(files)
    }

    /// Tên các tin nhắn phát sóng đang được dùng trong các khối.
    static func usedBroadcastNames(in targets: [Target]) -> [String] {
        var s = Set<String>()
        for t in targets {
            for b in t.blocks.values {
                if let n = b.fields["BROADCAST_OPTION"]?.asString, !n.isEmpty { s.insert(n) }
                for v in b.inputs.values {
                    if case .broadcast(let n) = v, !n.isEmpty { s.insert(n) }
                }
            }
        }
        return s.sorted()
    }

    /// Tên tin nhắn đã khai báo trong project.json gốc.
    var declaredBroadcasts: [String] {
        let ts = (rawJSON["targets"] as? [[String: Any]]) ?? []
        var s = Set<String>()
        for t in ts {
            if let bc = t["broadcasts"] as? [String: Any] {
                for v in bc.values { if let n = v as? String { s.insert(n) } }
            }
        }
        return s.sorted()
    }
}
