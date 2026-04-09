import Foundation

// MARK: - Protocol

/// Types that can be initialized from JSON and serialized back.
/// Generated types conform to this automatically.
public protocol JSONParseable {
    init(json: Any) throws
    func toJSON() -> Any
    func toTypedJSON() -> Any
}

extension JSONParseable {
    public func toTypedJSON() -> Any { toJSON() }
}

// MARK: - UnknownStrippable

public protocol UnknownStrippable {
    func strippingUnknown() -> Self?
}

extension UnknownStrippable {
    public func strippingUnknown() -> Self? { self }
}

// MARK: - JSONReader

/// Lightweight wrapper around `[String: Any]` for safe typed extraction.
/// Used by generated `init(json:)` to reduce boilerplate.
public struct JSONReader {
    public let dict: [String: Any]

    public init(_ json: Any, context: StaticString = "") throws {
        guard let d = json as? [String: Any] else {
            throw JSONParseError.typeMismatch(expected: "[String: Any]", in: "\(context)")
        }
        self.dict = d
    }

    // MARK: Optional primitives

    public func string(_ k: String) -> String? {
        dict[k] as? String
    }

    public func string(_ k: String, alt a: String) -> String? {
        (dict[k] ?? dict[a]) as? String
    }

    public func string(_ k: String, alt a: [String]) -> String? {
        if let v = dict[k] as? String { return v }
        for ak in a { if let v = dict[ak] as? String { return v } }
        return nil
    }

    public func int(_ k: String) -> Int? {
        (dict[k] as? NSNumber)?.intValue
    }

    public func int(_ k: String, alt a: String) -> Int? {
        ((dict[k] ?? dict[a]) as? NSNumber)?.intValue
    }

    public func int(_ k: String, alt a: [String]) -> Int? {
        if let v = (dict[k] as? NSNumber)?.intValue { return v }
        for ak in a { if let v = (dict[ak] as? NSNumber)?.intValue { return v } }
        return nil
    }

    public func double(_ k: String) -> Double? {
        dict[k] as? Double
    }

    public func double(_ k: String, alt a: String) -> Double? {
        (dict[k] ?? dict[a]) as? Double
    }

    public func double(_ k: String, alt a: [String]) -> Double? {
        if let v = dict[k] as? Double { return v }
        for ak in a { if let v = dict[ak] as? Double { return v } }
        return nil
    }

    public func bool(_ k: String) -> Bool? {
        dict[k] as? Bool
    }

    public func bool(_ k: String, alt a: String) -> Bool? {
        (dict[k] ?? dict[a]) as? Bool
    }

    public func bool(_ k: String, alt a: [String]) -> Bool? {
        if let v = dict[k] as? Bool { return v }
        for ak in a { if let v = dict[ak] as? Bool { return v } }
        return nil
    }

    public func raw(_ k: String) -> Any? {
        dict[k]
    }

    public func raw(_ k: String, alt a: String) -> Any? {
        dict[k] ?? dict[a]
    }

    public func raw(_ k: String, alt a: [String]) -> Any? {
        if let v = dict[k] { return v }
        for ak in a { if let v = dict[ak] { return v } }
        return nil
    }

    public func rawArray(_ k: String) -> [Any]? {
        dict[k] as? [Any]
    }

    public func rawArray(_ k: String, alt a: String) -> [Any]? {
        (dict[k] ?? dict[a]) as? [Any]
    }

    public func rawArray(_ k: String, alt a: [String]) -> [Any]? {
        if let v = dict[k] as? [Any] { return v }
        for ak in a { if let v = dict[ak] as? [Any] { return v } }
        return nil
    }

    public func rawDict(_ k: String) -> [String: Any]? {
        dict[k] as? [String: Any]
    }

    public func stringDict(_ k: String) -> [String: String]? {
        (dict[k] as? [String: Any])?.compactMapValues { $0 as? String }
    }

    public func stringDict(_ k: String, alt a: String) -> [String: String]? {
        ((dict[k] ?? dict[a]) as? [String: Any])?.compactMapValues { $0 as? String }
    }

    public func stringDict(_ k: String, alt a: [String]) -> [String: String]? {
        if let v = (dict[k] as? [String: Any])?.compactMapValues({ $0 as? String }) { return v }
        for ak in a { if let v = (dict[ak] as? [String: Any])?.compactMapValues({ $0 as? String }) { return v } }
        return nil
    }

    // MARK: Required primitives

    public func need(_ k: String, _ ctx: StaticString = "") throws -> String {
        guard let v = dict[k] as? String else {
            throw JSONParseError.missingField(k, in: "\(ctx)")
        }
        return v
    }

    public func need(_ k: String, alt a: String, _ ctx: StaticString = "") throws -> String {
        guard let v = (dict[k] ?? dict[a]) as? String else {
            throw JSONParseError.missingField(k, in: "\(ctx)")
        }
        return v
    }

    public func need(_ k: String, alt a: [String], _ ctx: StaticString = "") throws -> String {
        if let v = dict[k] as? String { return v }
        for ak in a { if let v = dict[ak] as? String { return v } }
        throw JSONParseError.missingField(k, in: "\(ctx)")
    }

    public func needInt(_ k: String, _ ctx: StaticString = "") throws -> Int {
        guard let v = (dict[k] as? NSNumber)?.intValue else {
            throw JSONParseError.missingField(k, in: "\(ctx)")
        }
        return v
    }

    public func needInt(_ k: String, alt a: String, _ ctx: StaticString = "") throws -> Int {
        guard let v = ((dict[k] ?? dict[a]) as? NSNumber)?.intValue else {
            throw JSONParseError.missingField(k, in: "\(ctx)")
        }
        return v
    }

    public func needInt(_ k: String, alt a: [String], _ ctx: StaticString = "") throws -> Int {
        if let v = (dict[k] as? NSNumber)?.intValue { return v }
        for ak in a { if let v = (dict[ak] as? NSNumber)?.intValue { return v } }
        throw JSONParseError.missingField(k, in: "\(ctx)")
    }

    public func needDouble(_ k: String, _ ctx: StaticString = "") throws -> Double {
        guard let v = dict[k] as? Double else {
            throw JSONParseError.missingField(k, in: "\(ctx)")
        }
        return v
    }

    public func needDouble(_ k: String, alt a: String, _ ctx: StaticString = "") throws -> Double {
        guard let v = (dict[k] ?? dict[a]) as? Double else {
            throw JSONParseError.missingField(k, in: "\(ctx)")
        }
        return v
    }

    public func needDouble(_ k: String, alt a: [String], _ ctx: StaticString = "") throws -> Double {
        if let v = dict[k] as? Double { return v }
        for ak in a { if let v = dict[ak] as? Double { return v } }
        throw JSONParseError.missingField(k, in: "\(ctx)")
    }

    public func needBool(_ k: String, _ ctx: StaticString = "") throws -> Bool {
        guard let v = dict[k] as? Bool else {
            throw JSONParseError.missingField(k, in: "\(ctx)")
        }
        return v
    }

    public func needBool(_ k: String, alt a: String, _ ctx: StaticString = "") throws -> Bool {
        guard let v = (dict[k] ?? dict[a]) as? Bool else {
            throw JSONParseError.missingField(k, in: "\(ctx)")
        }
        return v
    }

    public func needBool(_ k: String, alt a: [String], _ ctx: StaticString = "") throws -> Bool {
        if let v = dict[k] as? Bool { return v }
        for ak in a { if let v = dict[ak] as? Bool { return v } }
        throw JSONParseError.missingField(k, in: "\(ctx)")
    }

    public func needRaw(_ k: String, _ ctx: StaticString = "") throws -> Any {
        guard let v = dict[k] else {
            throw JSONParseError.missingField(k, in: "\(ctx)")
        }
        return v
    }

    public func needArray(_ k: String, _ ctx: StaticString = "") throws -> [Any] {
        guard let v = dict[k] as? [Any] else {
            throw JSONParseError.missingField(k, in: "\(ctx)")
        }
        return v
    }

    // MARK: Nested JSONParseable

    public func decode<T: JSONParseable>(_ k: String) throws -> T {
        try T(json: dict[k] ?? [:] as [String: Any])
    }

    public func decode<T: JSONParseable>(_ k: String, alt a: String) throws -> T {
        try T(json: dict[k] ?? dict[a] ?? [:] as [String: Any])
    }

    public func decode<T: JSONParseable>(_ k: String, alt a: [String]) throws -> T {
        if let v = dict[k] { return try T(json: v) }
        for ak in a { if let v = dict[ak] { return try T(json: v) } }
        return try T(json: [:] as [String: Any])
    }

    public func decodeIfPresent<T: JSONParseable>(_ k: String) -> T? {
        guard let v = dict[k] else { return nil }
        return try? T(json: v)
    }

    public func decodeIfPresent<T: JSONParseable>(_ k: String, alt a: String) -> T? {
        guard let v = dict[k] ?? dict[a] else { return nil }
        return try? T(json: v)
    }

    public func decodeIfPresent<T: JSONParseable>(_ k: String, alt a: [String]) -> T? {
        if let v = dict[k] { return try? T(json: v) }
        for ak in a { if let v = dict[ak] { return try? T(json: v) } }
        return nil
    }

    public func decodeArray<T: JSONParseable>(_ k: String) throws -> [T] {
        guard let arr = dict[k] as? [Any] else { return [] }
        return try arr.map { try T(json: $0) }
    }

    public func decodeArray<T: JSONParseable>(_ k: String, alt a: String) throws -> [T] {
        guard let arr = (dict[k] ?? dict[a]) as? [Any] else { return [] }
        return try arr.map { try T(json: $0) }
    }

    public func decodeArray<T: JSONParseable>(_ k: String, alt a: [String]) throws -> [T] {
        if let arr = dict[k] as? [Any] { return try arr.map { try T(json: $0) } }
        for ak in a { if let arr = dict[ak] as? [Any] { return try arr.map { try T(json: $0) } } }
        return []
    }

    public func decodeArrayIfPresent<T: JSONParseable>(_ k: String) throws -> [T]? {
        guard let arr = dict[k] as? [Any] else { return nil }
        return try arr.map { try T(json: $0) }
    }

    public func decodeArrayIfPresent<T: JSONParseable>(_ k: String, alt a: String) throws -> [T]? {
        guard let arr = (dict[k] ?? dict[a]) as? [Any] else { return nil }
        return try arr.map { try T(json: $0) }
    }

    public func decodeArrayIfPresent<T: JSONParseable>(_ k: String, alt a: [String]) throws -> [T]? {
        if let arr = dict[k] as? [Any] { return try arr.map { try T(json: $0) } }
        for ak in a { if let arr = dict[ak] as? [Any] { return try arr.map { try T(json: $0) } } }
        return nil
    }

    public func decodeMap<T: JSONParseable>(_ k: String) throws -> [String: T]? {
        guard let raw = dict[k] as? [String: Any] else { return nil }
        return try raw.mapValues { try T(json: $0) }
    }

    public func decodeMap<T: JSONParseable>(_ k: String, alt a: String) throws -> [String: T]? {
        guard let raw = (dict[k] ?? dict[a]) as? [String: Any] else { return nil }
        return try raw.mapValues { try T(json: $0) }
    }

    public func decodeMap<T: JSONParseable>(_ k: String, alt a: [String]) throws -> [String: T]? {
        if let raw = dict[k] as? [String: Any] { return try raw.mapValues { try T(json: $0) } }
        for ak in a { if let raw = dict[ak] as? [String: Any] { return try raw.mapValues { try T(json: $0) } } }
        return nil
    }

    // MARK: Primitive arrays

    public func stringArray(_ k: String) -> [String]? {
        (dict[k] as? [Any])?.compactMap { $0 as? String }
    }

    public func stringArray(_ k: String, alt a: String) -> [String]? {
        ((dict[k] ?? dict[a]) as? [Any])?.compactMap { $0 as? String }
    }

    public func stringArray(_ k: String, alt a: [String]) -> [String]? {
        if let v = (dict[k] as? [Any])?.compactMap({ $0 as? String }) { return v }
        for ak in a { if let v = (dict[ak] as? [Any])?.compactMap({ $0 as? String }) { return v } }
        return nil
    }

    public func intArray(_ k: String) -> [Int]? {
        (dict[k] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue }
    }

    public func intArray(_ k: String, alt a: String) -> [Int]? {
        ((dict[k] ?? dict[a]) as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue }
    }

    public func intArray(_ k: String, alt a: [String]) -> [Int]? {
        if let v = (dict[k] as? [Any])?.compactMap({ ($0 as? NSNumber)?.intValue }) { return v }
        for ak in a { if let v = (dict[ak] as? [Any])?.compactMap({ ($0 as? NSNumber)?.intValue }) { return v } }
        return nil
    }
}

// MARK: - Generic decode helper

/// Disambiguates JSONParseable type init when enum case names shadow type names.
/// Usage: `let _v: SomeType = try _jp(json)` inside an enum with `case SomeType(SomeType)`.
public func _jp<T: JSONParseable>(_ json: Any) throws -> T { try T(json: json) }

// MARK: - JSONWriter

/// Helper for building `[String: Any]` dictionaries in generated `toJSON()`.
public struct JSONWriter {
    public var dict: [String: Any] = [:]

    public init() {}

    // Optional scalars — nil values are omitted
    public mutating func set(_ k: String, _ v: String?) { if let v { dict[k] = v } }
    public mutating func set(_ k: String, _ v: Int?) { if let v { dict[k] = v } }
    public mutating func set(_ k: String, _ v: Double?) { if let v { dict[k] = v } }
    public mutating func set(_ k: String, _ v: Bool?) { if let v { dict[k] = v } }
    public mutating func set(_ k: String, _ v: Any?) { if let v { dict[k] = v } }

    // Required scalars — always written
    public mutating func put(_ k: String, _ v: Any) { dict[k] = v }

    // JSONParseable — optional
    public mutating func set<T: JSONParseable>(_ k: String, _ v: T?) {
        if let v { dict[k] = v.toJSON() }
    }

    // JSONParseable — required
    public mutating func put<T: JSONParseable>(_ k: String, _ v: T) {
        dict[k] = v.toJSON()
    }

    // JSONParseable arrays
    public mutating func set<T: JSONParseable>(_ k: String, _ v: [T]?) {
        if let v { dict[k] = v.map { $0.toJSON() } }
    }

    public mutating func put<T: JSONParseable>(_ k: String, _ v: [T]) {
        dict[k] = v.map { $0.toJSON() }
    }

    // JSONParseable maps
    public mutating func set<T: JSONParseable>(_ k: String, _ v: [String: T]?) {
        if let v { dict[k] = v.mapValues { $0.toJSON() } }
    }
}
