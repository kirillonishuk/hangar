import Foundation

public struct JSONMember: Equatable, Sendable {
    public var key: String
    public var value: JSONValue
    public init(key: String, value: JSONValue) { self.key = key; self.value = value }
}

/// Order-preserving JSON tree: objects keep key order, numbers keep their literal, so unknown settings survive a rewrite.
public indirect enum JSONValue: Equatable, Sendable {
    case object([JSONMember])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
}

public enum IntegrationError: Error, Equatable {
    case invalidJSON(line: Int)
    case notAnObject
    case unsupportedNotify
    case invalidTOML(line: Int)
    case changedOnDisk
}

public func parseJSON(_ text: String) throws(IntegrationError) -> JSONValue {
    var p = JSONParser(bytes: Array(text.utf8))
    p.skipSpace()
    let v = try p.value(depth: 0)
    p.skipSpace()
    guard p.i == p.bytes.count else { throw p.fail() }
    return v
}

public func printJSON(_ value: JSONValue) -> String {
    var out = ""
    write(value, indent: "", into: &out)
    return out + "\n"
}

private func write(_ v: JSONValue, indent: String, into out: inout String) {
    switch v {
    case .object(let m) where m.isEmpty: out += "{}"
    case .array(let a) where a.isEmpty: out += "[]"
    case .object(let members):
        let inner = indent + "  "
        out += "{\n"
        for (n, m) in members.enumerated() {
            out += inner + quoted(m.key) + ": "
            write(m.value, indent: inner, into: &out)
            out += n == members.count - 1 ? "\n" : ",\n"
        }
        out += indent + "}"
    case .array(let items):
        let inner = indent + "  "
        out += "[\n"
        for (n, item) in items.enumerated() {
            out += inner
            write(item, indent: inner, into: &out)
            out += n == items.count - 1 ? "\n" : ",\n"
        }
        out += indent + "]"
    case .string(let s): out += quoted(s)
    case .number(let n): out += n
    case .bool(let b): out += b ? "true" : "false"
    case .null: out += "null"
    }
}

private func quoted(_ s: String) -> String {
    var out = "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{8}": out += "\\b"
        case "\u{c}": out += "\\f"
        case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
        default: out.unicodeScalars.append(u)
        }
    }
    return out + "\""
}

private struct JSONParser {
    let bytes: [UInt8]
    var i = 0

    func fail() -> IntegrationError {
        .invalidJSON(line: bytes[..<min(i, bytes.count)].reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) })
    }

    mutating func skipSpace() {
        while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
    }

    mutating func expect(_ s: String) throws(IntegrationError) {
        for b in s.utf8 {
            guard i < bytes.count, bytes[i] == b else { throw fail() }
            i += 1
        }
    }

    mutating func value(depth: Int) throws(IntegrationError) -> JSONValue {
        guard i < bytes.count, depth < 512 else { throw fail() }
        switch bytes[i] {
        case UInt8(ascii: "{"):
            i += 1
            var members: [JSONMember] = []
            skipSpace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object([]) }
            while true {
                skipSpace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail() }
                let key = try string()
                skipSpace()
                try expect(":")
                skipSpace()
                members.append(JSONMember(key: key, value: try value(depth: depth + 1)))
                skipSpace()
                guard i < bytes.count else { throw fail() }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                throw fail()
            }
        case UInt8(ascii: "["):
            i += 1
            var items: [JSONValue] = []
            skipSpace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array([]) }
            while true {
                skipSpace()
                items.append(try value(depth: depth + 1))
                skipSpace()
                guard i < bytes.count else { throw fail() }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw fail()
            }
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return .number(try number())
        }
    }

    private func isDigit(_ k: Int) -> Bool { k < bytes.count && bytes[k] >= 0x30 && bytes[k] <= 0x39 }

    mutating func number() throws(IntegrationError) -> String {
        let start = i
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
        guard isDigit(i) else { throw fail() }
        if bytes[i] == UInt8(ascii: "0") { i += 1 } else { while isDigit(i) { i += 1 } }
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            i += 1
            guard isDigit(i) else { throw fail() }
            while isDigit(i) { i += 1 }
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            i += 1
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard isDigit(i) else { throw fail() }
            while isDigit(i) { i += 1 }
        }
        return String(decoding: bytes[start..<i], as: UTF8.self)
    }

    mutating func hex4() throws(IntegrationError) -> UInt32 {
        guard i + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16) else { throw fail() }
        i += 4
        return v
    }

    mutating func string() throws(IntegrationError) -> String {
        i += 1  // opening quote
        var out: [UInt8] = []
        while true {
            guard i < bytes.count else { throw fail() }
            let b = bytes[i]
            if b == UInt8(ascii: "\"") { i += 1; break }
            guard b >= 0x20 else { throw fail() }
            guard b == UInt8(ascii: "\\") else { out.append(b); i += 1; continue }
            i += 1
            guard i < bytes.count else { throw fail() }
            let e = bytes[i]
            i += 1
            switch e {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "u"):
                var code = try hex4()
                if (0xD800..<0xDC00).contains(code) {
                    try expect("\\u")
                    let low = try hex4()
                    guard (0xDC00..<0xE000).contains(low) else { throw fail() }
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                }
                guard let scalar = Unicode.Scalar(code) else { throw fail() }
                out.append(contentsOf: Array(String(Character(scalar)).utf8))
            default: throw fail()
            }
        }
        // Raw bytes come from a Swift String, so they are valid UTF-8.
        return String(decoding: out, as: UTF8.self)
    }
}
