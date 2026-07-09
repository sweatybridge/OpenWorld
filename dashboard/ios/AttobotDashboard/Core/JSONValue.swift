import Foundation

/// Recursive JSON value that decodes arbitrary JSON without a concrete type.
/// Used for info/result/payload/detail and untyped execution rows. Mirrors the
/// JS `unknown`/`Record<string, unknown>` used in the RN client.
///
/// NOTE: JSONValue intentionally does NOT participate in any snake_case key
/// conversion — its object keys are the raw keys the server emitted, so JsonView
/// can display the data verbatim (mirrors RN `JSON.stringify`). Typed structs
/// carry their own CodingKeys instead of a global keyDecodingStrategy.
enum JSONValue: Codable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n == n.rounded() && abs(n) < 1e15 {
                try c.encode(Int64(n))
            } else {
                try c.encode(n)
            }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // MARK: - Accessors

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
    /// Like `numberValue` but also parses numeric strings (mirrors JS `Number()`);
    /// used for execution rows whose numeric fields may arrive as text.
    var numericValue: Double? {
        if case .number(let n) = self { return n }
        if case .string(let s) = self { return Double(s) }
        return nil
    }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    // MARK: - Pretty printing (2-space, sorted keys)

    /// 2-space pretty JSON. Strings that themselves encode JSON are NOT parsed
    /// here — `parsedIfString()` does that on demand in JsonView.
    func pretty(indent: Int = 2) -> String {
        var out = ""
        JSONValue.writePretty(self, level: 0, indent: indent, into: &out)
        return out
    }

    /// Attempt to parse a `.string` value as JSON and return the parsed value.
    /// Used by JsonView so result fields arriving as JSON-encoded strings render
    /// re-indented (mirrors RN `JSON.stringify(JSON.parse(value), null, 2)`).
    func parsedIfString() -> JSONValue {
        guard case .string(let s) = self,
              let data = s.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return self
        }
        return parsed
    }

    private static func writePretty(_ v: JSONValue, level: Int, indent: Int, into out: inout String) {
        switch v {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .number(let n):
            if n.isFinite {
                if n == n.rounded() && abs(n) < 1e15 { out += String(Int64(n)) }
                else { out += String(n) }
            } else {
                out += "null"
            }
        case .string(let s):
            out += quote(s)
        case .array(let arr):
            if arr.isEmpty {
                out += "[]"
            } else {
                out += "[\n"
                for (i, e) in arr.enumerated() {
                    out += String(repeating: " ", count: (level + 1) * indent)
                    writePretty(e, level: level + 1, indent: indent, into: &out)
                    out += i < arr.count - 1 ? ",\n" : "\n"
                }
                out += String(repeating: " ", count: level * indent) + "]"
            }
        case .object(let o):
            if o.isEmpty {
                out += "{}"
            } else {
                out += "{\n"
                let keys = o.keys.sorted()
                for (i, k) in keys.enumerated() {
                    out += String(repeating: " ", count: (level + 1) * indent)
                    out += "\(quote(k)): "
                    writePretty(o[k]!, level: level + 1, indent: indent, into: &out)
                    out += i < keys.count - 1 ? ",\n" : "\n"
                }
                out += String(repeating: " ", count: level * indent) + "}"
            }
        }
    }

    /// JSON-encode a String to get correct escaping + surrounding quotes.
    private static func quote(_ s: String) -> String {
        let data = (try? JSONEncoder().encode(s)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "\"\""
    }
}
