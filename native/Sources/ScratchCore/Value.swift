import Foundation

/// Giá trị động của Scratch: số, chuỗi hoặc boolean (giống Cast.js trong scratch-vm).
public enum ScratchValue: Equatable {
    case number(Double)
    case string(String)
    case bool(Bool)

    public static let empty = ScratchValue.string("")

    public var asNumber: Double {
        switch self {
        case .number(let d): return d.isNaN ? 0 : d
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return ScratchValue.parseNumber(s) ?? 0
        }
    }

    public var asString: String {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .number(let d): return ScratchValue.format(d)
        }
    }

    public var asBool: Bool {
        switch self {
        case .bool(let b): return b
        case .number(let d): return d != 0 && !d.isNaN
        case .string(let s):
            return !(s.isEmpty || s == "0" || s.lowercased() == "false")
        }
    }

    /// Số nếu giá trị có thể hiểu là số, ngược lại nil.
    public var numericValue: Double? {
        switch self {
        case .number(let d): return d.isNaN ? nil : d
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return ScratchValue.parseNumber(s)
        }
    }

    public var isInteger: Bool {
        switch self {
        case .number(let d): return d == d.rounded()
        case .bool: return true
        case .string(let s): return !s.contains(".")
        }
    }

    static func parseNumber(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        let lower = t.lowercased()
        if lower.contains("inf") || lower.contains("nan") { return nil }
        return Double(t)
    }

    static func format(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
        if d == d.rounded() && abs(d) < 1e15 { return String(Int64(d)) }
        return "\(d)"
    }

    /// So sánh theo luật Scratch: số nếu cả hai là số, ngược lại so chuỗi không phân biệt hoa thường.
    public static func compare(_ a: ScratchValue, _ b: ScratchValue) -> Int {
        if let x = a.numericValue, let y = b.numericValue {
            if x < y { return -1 }
            if x > y { return 1 }
            return 0
        }
        let sa = a.asString.lowercased()
        let sb = b.asString.lowercased()
        if sa < sb { return -1 }
        if sa == sb { return 0 }
        return 1
    }

    /// Chuyển giá trị JSON (từ project.json) sang ScratchValue.
    public static func from(json any: Any?) -> ScratchValue {
        if let s = any as? String { return .string(s) }
        if let n = any as? NSNumber {
            if CFGetTypeIDCompat(n) { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        }
        if let b = any as? Bool { return .bool(b) }
        if let d = any as? Double { return .number(d) }
        if let i = any as? Int { return .number(Double(i)) }
        return .string("")
    }

    public var jsonObject: Any {
        switch self {
        case .number(let d): return d
        case .string(let s): return s
        case .bool(let b): return b
        }
    }
}

private func CFGetTypeIDCompat(_ n: NSNumber) -> Bool {
    #if canImport(Darwin)
    return CFGetTypeID(n) == CFBooleanGetTypeID()
    #else
    return false
    #endif
}
