import Foundation

/// String-keyed coding key used by every hand-written decoder in the SDK.
struct AnyCodingKey: CodingKey, ExpressibleByStringLiteral {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { self.stringValue = string }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    init(stringLiteral value: String) { self.stringValue = value }
}

typealias JSONContainer = KeyedDecodingContainer<AnyCodingKey>

extension KeyedDecodingContainer where Key == AnyCodingKey {
    /// First of `keys` that is present and decodes as `T`. A missing key, a
    /// `null`, or a type mismatch all yield `nil`: the protocol grows and
    /// drifts, and one odd field must never cost the whole message.
    func lenient<T: Decodable>(_ type: T.Type = T.self, _ keys: String...) -> T? {
        for key in keys {
            if let value = try? decodeIfPresent(T.self, forKey: AnyCodingKey(key)) { return value }
        }
        return nil
    }

    /// Like ``lenient(_:_:)`` but throws when no key decodes. Reserved for a
    /// message's structural core; the caller degrades the whole message to
    /// `.unknown` on failure.
    func required<T: Decodable>(_ type: T.Type = T.self, _ keys: String...) throws -> T {
        for key in keys {
            if let value = try? decodeIfPresent(T.self, forKey: AnyCodingKey(key)) { return value }
        }
        throw DecodingError.keyNotFound(
            AnyCodingKey(keys.first ?? ""),
            .init(codingPath: codingPath, debugDescription: "missing or mistyped \(keys)"))
    }

    /// A boolean, also accepting `"true"`/`"false"`: models sometimes quote
    /// tool arguments.
    func lenientBool(_ key: String) -> Bool? {
        if let value = lenient(Bool.self, key) { return value }
        switch lenient(String.self, key)?.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// An integer, also accepting an integral number or a numeric string.
    func lenientInt(_ key: String) -> Int? {
        if let value = lenient(Int.self, key) { return value }
        if let value = lenient(Double.self, key), let int = Int(exactly: value.rounded(.towardZero)) { return int }
        return lenient(String.self, key).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// An array whose malformed elements are dropped instead of failing it.
    func lenientArray<T: Decodable>(_ type: T.Type, _ key: String) -> [T]? {
        (try? decodeIfPresent([Lenient<T>].self, forKey: AnyCodingKey(key)))?.compactMap(\.value)
    }

    /// An ISO-8601 timestamp, with or without fractional seconds.
    func timestamp(_ keys: String...) -> Date? {
        for key in keys {
            if let raw = try? decodeIfPresent(String.self, forKey: AnyCodingKey(key)),
                let date = ISO8601.parse(raw)
            {
                return date
            }
        }
        return nil
    }

    /// Content that the API allows as either a bare string or a block array.
    func contentBlocks(_ key: String) -> [ContentBlock]? {
        if let text = try? decodeIfPresent(String.self, forKey: AnyCodingKey(key)) { return [.text(text)] }
        return try? decodeIfPresent([ContentBlock].self, forKey: AnyCodingKey(key))
    }
}

/// Decodes `T`, or `nil` when the value does not fit.
private struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

enum ISO8601 {
    static func parse(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: fractional) { return date }
        return try? Date(string, strategy: .iso8601)
    }

    static func format(_ date: Date) -> String { date.formatted(fractional) }

    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

extension Decoder {
    /// This decoder's value as a raw ``JSONValue`` (the `.unknown` payload).
    func rawValue() -> JSONValue {
        (try? JSONValue(from: self)) ?? .null
    }
}
