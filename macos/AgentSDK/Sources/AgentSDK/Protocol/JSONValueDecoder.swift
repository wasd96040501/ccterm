import Foundation

/// Decodes a type straight from a ``JSONValue`` tree — what
/// ``JSONValue/decode(_:)`` does, without writing the tree out as text and
/// scanning it back. A tool's recorded output can hold a whole file; a round
/// trip through `JSONEncoder` and `JSONDecoder` copied and re-parsed it on
/// every read, here its strings are handed over as they are.
///
/// Reads as `JSONDecoder` does with its default strategies: keys as written,
/// a number into any numeric type it fits exactly, `Date` deferred to its own
/// `Decodable`, `Data` from base64, `URL` from a string, and the same
/// `DecodingError`s for a missing key, a `null` or a mismatched type — save
/// that a number that doesn't fit names its key, where `JSONDecoder`'s path
/// is empty.
struct JSONValueDecoder: Decoder {
    let value: JSONValue
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    init(_ value: JSONValue, codingPath: [CodingKey] = []) {
        self.value = value
        self.codingPath = codingPath
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let object) = value else {
            throw Self.mismatch([String: Any].self, value, codingPath)
        }
        return KeyedDecodingContainer(Keyed<Key>(object: object, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard case .array(let array) = value else { throw Self.mismatch([Any].self, value, codingPath) }
        return Unkeyed(array: array, codingPath: codingPath)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        Single(value: value, codingPath: codingPath)
    }

    // MARK: - Reading one value

    static func unbox<T: Decodable>(_ type: T.Type, _ value: JSONValue, _ path: [CodingKey]) throws -> T {
        if case .null = value, !(T.self is ExpressibleByNilLiteral.Type) {
            throw DecodingError.valueNotFound(
                T.self, .init(codingPath: path, debugDescription: "Expected \(T.self) value but found null instead."))
        }
        switch T.self {
        case is String.Type:
            guard case .string(let string) = value else { throw mismatch(T.self, value, path) }
            return string as! T
        case is Bool.Type:
            guard case .bool(let bool) = value else { throw mismatch(T.self, value, path) }
            return bool as! T
        case is Double.Type: return try number(value, path) as! T
        case is Float.Type: return Float(try number(value, path)) as! T
        case is Int.Type: return try integer(Int.self, value, path) as! T
        case is Int8.Type: return try integer(Int8.self, value, path) as! T
        case is Int16.Type: return try integer(Int16.self, value, path) as! T
        case is Int32.Type: return try integer(Int32.self, value, path) as! T
        case is Int64.Type: return try integer(Int64.self, value, path) as! T
        case is UInt.Type: return try integer(UInt.self, value, path) as! T
        case is UInt8.Type: return try integer(UInt8.self, value, path) as! T
        case is UInt16.Type: return try integer(UInt16.self, value, path) as! T
        case is UInt32.Type: return try integer(UInt32.self, value, path) as! T
        case is UInt64.Type: return try integer(UInt64.self, value, path) as! T
        case is Decimal.Type: return Decimal(try number(value, path)) as! T
        case is URL.Type:
            guard case .string(let string) = value else { throw mismatch(T.self, value, path) }
            guard let url = URL(string: string) else {
                throw DecodingError.dataCorrupted(.init(codingPath: path, debugDescription: "Invalid URL string."))
            }
            return url as! T
        case is Data.Type:
            guard case .string(let string) = value else { throw mismatch(T.self, value, path) }
            guard let data = Data(base64Encoded: string) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: path, debugDescription: "Encountered Data is not valid Base64."))
            }
            return data as! T
        default:
            return try T(from: JSONValueDecoder(value, codingPath: path))
        }
    }

    private static func number(_ value: JSONValue, _ path: [CodingKey]) throws -> Double {
        guard case .number(let number) = value else { throw mismatch(Double.self, value, path) }
        return number
    }

    /// A number that is whole and in range, as `JSONDecoder` reads `5` (and
    /// the `5.0` a round trip through `JSONEncoder` would have written as `5`).
    private static func integer<I: FixedWidthInteger>(
        _ type: I.Type, _ value: JSONValue, _ path: [CodingKey]
    )
        throws -> I
    {
        let number = try number(value, path)
        guard let integer = I(exactly: number) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: path, debugDescription: "Parsed JSON number <\(number)> does not fit in \(I.self)."))
        }
        return integer
    }

    static func mismatch(_ type: Any.Type, _ value: JSONValue, _ path: [CodingKey]) -> DecodingError {
        let found: String
        switch value {
        case .null: found = "null"
        case .bool: found = "bool"
        case .number: found = "number"
        case .string: found = "a string"
        case .array: found = "an array"
        case .object: found = "a dictionary"
        }
        return DecodingError.typeMismatch(
            type, .init(codingPath: path, debugDescription: "Expected to decode \(type) but found \(found) instead."))
    }

    // MARK: - Containers

    private struct Keyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
        let object: [String: JSONValue]
        let codingPath: [CodingKey]

        var allKeys: [Key] { object.keys.compactMap(Key.init(stringValue:)) }

        func contains(_ key: Key) -> Bool { object[key.stringValue] != nil }

        private func value(for key: Key) throws -> JSONValue {
            guard let value = object[key.stringValue] else {
                throw DecodingError.keyNotFound(
                    key,
                    .init(
                        codingPath: codingPath,
                        debugDescription: "No value associated with key \(key) (\"\(key.stringValue)\")."))
            }
            return value
        }

        func decodeNil(forKey key: Key) throws -> Bool { try value(for: key).isNull }

        func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
            try JSONValueDecoder.unbox(T.self, try value(for: key), codingPath + [key])
        }

        func nestedContainer<NestedKey: CodingKey>(
            keyedBy type: NestedKey.Type, forKey key: Key
        ) throws
            -> KeyedDecodingContainer<NestedKey>
        {
            try JSONValueDecoder(try value(for: key), codingPath: codingPath + [key]).container(keyedBy: type)
        }

        func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
            try JSONValueDecoder(try value(for: key), codingPath: codingPath + [key]).unkeyedContainer()
        }

        func superDecoder() throws -> Decoder {
            JSONValueDecoder(object["super"] ?? .null, codingPath: codingPath + [AnyCodingKey("super")])
        }

        func superDecoder(forKey key: Key) throws -> Decoder {
            JSONValueDecoder(object[key.stringValue] ?? .null, codingPath: codingPath + [key])
        }
    }

    private struct Unkeyed: UnkeyedDecodingContainer {
        let array: [JSONValue]
        let codingPath: [CodingKey]
        private(set) var currentIndex = 0

        init(array: [JSONValue], codingPath: [CodingKey]) {
            self.array = array
            self.codingPath = codingPath
        }

        var count: Int? { array.count }
        var isAtEnd: Bool { currentIndex >= array.count }

        private var path: [CodingKey] { codingPath + [IndexKey(currentIndex)] }

        private func current<T>(_ type: T.Type) throws -> JSONValue {
            guard !isAtEnd else {
                throw DecodingError.valueNotFound(
                    type, .init(codingPath: path, debugDescription: "Unkeyed container is at end."))
            }
            return array[currentIndex]
        }

        mutating func decodeNil() throws -> Bool {
            guard try current(Any?.self).isNull else { return false }
            currentIndex += 1
            return true
        }

        mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
            let decoded = try JSONValueDecoder.unbox(T.self, try current(T.self), path)
            currentIndex += 1
            return decoded
        }

        mutating func nestedContainer<NestedKey: CodingKey>(
            keyedBy type: NestedKey.Type
        ) throws
            -> KeyedDecodingContainer<NestedKey>
        {
            let container = try JSONValueDecoder(try current(type), codingPath: path).container(keyedBy: type)
            currentIndex += 1
            return container
        }

        mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
            let container = try JSONValueDecoder(try current([Any].self), codingPath: path).unkeyedContainer()
            currentIndex += 1
            return container
        }

        mutating func superDecoder() throws -> Decoder {
            let decoder = JSONValueDecoder(try current(Any.self), codingPath: path)
            currentIndex += 1
            return decoder
        }
    }

    /// An array element's place in a coding path, named as `JSONDecoder` names it.
    private struct IndexKey: CodingKey {
        let index: Int
        init(_ index: Int) { self.index = index }
        init?(stringValue: String) { nil }
        init?(intValue: Int) { self.init(intValue) }
        var stringValue: String { "Index \(index)" }
        var intValue: Int? { index }
    }

    private struct Single: SingleValueDecodingContainer {
        let value: JSONValue
        let codingPath: [CodingKey]

        func decodeNil() -> Bool { value.isNull }

        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            try JSONValueDecoder.unbox(T.self, value, codingPath)
        }
    }
}
