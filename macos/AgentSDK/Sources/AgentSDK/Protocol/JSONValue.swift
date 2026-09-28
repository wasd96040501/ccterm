import Foundation

/// A lossless, `Sendable` JSON value.
///
/// Used wherever the protocol is deliberately untyped: a tool call's `input`,
/// a tool's recorded result (`UserMessage.toolUseResult`), and the payload of
/// message kinds this SDK does not model (`Message.unknown`). Read it with the
/// subscripts and `*Value` accessors, or decode it into your own type with
/// ``decode(_:)``.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Accessors

extension JSONValue {
    /// Member of an object; `nil` for a missing key or a non-object.
    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// Element of an array; `nil` when out of range or not an array.
    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    /// The number as an `Int` when it is integral and in range.
    public var intValue: Int? {
        guard case .number(let n) = self, n.rounded() == n, let i = Int(exactly: n) else { return nil }
        return i
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Decodes this value into `type` (snake_case keys stay as written; map
    /// them with `CodingKeys`).
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            var items: [JSONValue] = []
            if let count = array.count { items.reserveCapacity(count) }
            while !array.isAtEnd { items.append(try array.decode(JSONValue.self)) }
            self = .array(items)
            return
        }
        if let object = try? decoder.container(keyedBy: AnyCodingKey.self) {
            var members: [String: JSONValue] = [:]
            members.reserveCapacity(object.allKeys.count)
            for key in object.allKeys {
                members[key.stringValue] = try object.decode(JSONValue.self, forKey: key)
            }
            self = .object(members)
            return
        }
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let s = try? single.decode(String.self) {
            self = .string(s)
        } else if let b = try? single.decode(Bool.self) {
            self = .bool(b)
        } else {
            self = .number(try single.decode(Double.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .null: try single.encodeNil()
        case .bool(let b): try single.encode(b)
        case .number(let n):
            if let i = Int(exactly: n) { try single.encode(i) } else { try single.encode(n) }
        case .string(let s): try single.encode(s)
        case .array(let a): try single.encode(a)
        case .object(let o): try single.encode(o)
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
