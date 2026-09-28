import Foundation

/// A value a ``SettingsKey`` can hold: anything with a `settings.json`
/// representation.
///
/// Scalars, arrays, string-keyed dictionaries and `JSONValue` conform. A
/// `String`-backed enum conforms by declaring it; a struct maps its fields
/// to a JSON object. Reading is lenient, like all decoding in the SDK: JSON
/// of the wrong shape yields `nil`, never a crash.
public protocol SettingsValue: Sendable {
    /// Reads the value from its `settings.json` form; `nil` when `json` has
    /// the wrong shape.
    init?(settingsJSON json: JSONValue)

    /// The value as written in `settings.json`.
    var settingsJSON: JSONValue { get }
}

extension SettingsValue where Self: RawRepresentable, RawValue == String {
    public init?(settingsJSON json: JSONValue) {
        guard let raw = json.stringValue else { return nil }
        self.init(rawValue: raw)
    }

    public var settingsJSON: JSONValue { .string(rawValue) }
}

extension Bool: SettingsValue {
    public init?(settingsJSON json: JSONValue) {
        guard let value = json.boolValue else { return nil }
        self = value
    }

    public var settingsJSON: JSONValue { .bool(self) }
}

extension Int: SettingsValue {
    public init?(settingsJSON json: JSONValue) {
        guard let value = json.intValue else { return nil }
        self = value
    }

    public var settingsJSON: JSONValue { .number(Double(self)) }
}

extension Double: SettingsValue {
    public init?(settingsJSON json: JSONValue) {
        guard let value = json.doubleValue else { return nil }
        self = value
    }

    public var settingsJSON: JSONValue { .number(self) }
}

extension String: SettingsValue {
    public init?(settingsJSON json: JSONValue) {
        guard let value = json.stringValue else { return nil }
        self = value
    }

    public var settingsJSON: JSONValue { .string(self) }
}

extension Array: SettingsValue where Element: SettingsValue {
    /// `nil` when `json` is not an array or any element has the wrong shape.
    public init?(settingsJSON json: JSONValue) {
        guard let array = json.arrayValue else { return nil }
        var elements: [Element] = []
        for item in array {
            guard let element = Element(settingsJSON: item) else { return nil }
            elements.append(element)
        }
        self = elements
    }

    public var settingsJSON: JSONValue { .array(map(\.settingsJSON)) }
}

extension Dictionary: SettingsValue where Key == String, Value: SettingsValue {
    /// `nil` when `json` is not an object or any value has the wrong shape.
    public init?(settingsJSON json: JSONValue) {
        guard let object = json.objectValue else { return nil }
        var values: [String: Value] = [:]
        for (key, item) in object {
            guard let value = Value(settingsJSON: item) else { return nil }
            values[key] = value
        }
        self = values
    }

    public var settingsJSON: JSONValue { .object(mapValues(\.settingsJSON)) }
}

extension JSONValue: SettingsValue {
    public init?(settingsJSON json: JSONValue) {
        self = json
    }

    public var settingsJSON: JSONValue { self }
}

extension Effort: SettingsValue {}

extension PermissionMode: SettingsValue {}

extension PermissionRule: SettingsValue {
    /// Parses the rule string settings use: `Bash(git status:*)` or a bare
    /// tool name. `Tool()` and `Tool(*)` mean the whole tool.
    public init?(settingsJSON json: JSONValue) {
        guard let rule = json.stringValue, !rule.isEmpty else { return nil }
        guard rule.hasSuffix(")"), let open = rule.firstIndex(of: "("), open != rule.startIndex else {
            self.init(toolName: rule)
            return
        }
        let content = String(rule[rule.index(after: open)..<rule.index(before: rule.endIndex)])
        let unescaped =
            content
            .replacingOccurrences(of: "\\(", with: "(")
            .replacingOccurrences(of: "\\)", with: ")")
            .replacingOccurrences(of: "\\\\", with: "\\")
        self.init(
            toolName: String(rule[..<open]),
            ruleContent: unescaped.isEmpty || unescaped == "*" ? nil : unescaped)
    }

    /// The rule string settings use, with parentheses and backslashes in the
    /// content escaped as the CLI writes them.
    public var settingsJSON: JSONValue {
        guard let ruleContent, !ruleContent.isEmpty else { return .string(toolName) }
        let escaped =
            ruleContent
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
        return .string("\(toolName)(\(escaped))")
    }
}
