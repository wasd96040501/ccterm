import Foundation

/// A `settings.json` object: top-level keys and their values.
///
/// It is what a settings layer holds and what the merged ``SettingsSnapshot/effective``
/// settings are, and it is how a session's flag layer is written — seeded by
/// ``SessionConfiguration/settings`` at launch and changed with
/// ``Session/applySettings(_:)``.
///
/// ```swift
/// var settings = Settings()
/// settings[.effortLevel] = .high
/// settings[.permissions] = PermissionSettings(allow: [PermissionRule(toolName: "Bash", ruleContent: "git status:*")])
/// settings.unset(.fastMode)
/// try await session.applySettings(settings)
/// ```
///
/// Read and write through a ``SettingsKey``. The string subscript reaches
/// any key the SDK does not name, as raw JSON.
///
/// **Absent vs. unset.** Assigning `nil` removes the entry from this value,
/// so applying it leaves that key alone. ``unset(_:)`` records a removal:
/// applying it withdraws the key's runtime value, so the key falls back to
/// its launch value, or to the layers beneath when it had none. Four keys
/// instead reset the session: `effortLevel` to the model's default effort,
/// `model` to Claude Code's default model, `agent` to none and `ultracode`
/// to off — the layer shows the fallback value, but
/// ``SettingsSnapshot/applied`` shows what the session runs with.
public struct Settings: Sendable, Equatable {
    /// The entries as JSON, keyed as in `settings.json`. A key recorded by
    /// ``unset(_:)`` maps to `null`.
    public private(set) var json: [String: JSONValue]

    public init() {
        self.json = [:]
    }

    /// Settings from a JSON object, such as a parsed `settings.json`. A
    /// `null` value is an unset key.
    public init(json: [String: JSONValue]) {
        self.json = json
    }

    public var isEmpty: Bool { json.isEmpty }

    /// The value for `key`; `nil` when the key is absent, unset, or holds
    /// JSON of another shape. Assigning `nil` removes the entry.
    public subscript<Value>(key: SettingsKey<Value>) -> Value? {
        get { json[key.rawValue].flatMap(Value.init(settingsJSON:)) }
        set { json[key.rawValue] = newValue?.settingsJSON }
    }

    /// The raw JSON for any key. Nothing checks the value: a value the CLI's
    /// schema rejects invalidates the whole layer it lands in.
    public subscript(key: String) -> JSONValue? {
        get { json[key] }
        set { json[key] = newValue }
    }

    /// Records that `key`'s runtime value is to be withdrawn when these
    /// settings are applied.
    public mutating func unset<Value>(_ key: SettingsKey<Value>) {
        json[key.rawValue] = .null
    }

    /// Whether `key` is recorded as unset.
    public func isUnset<Value>(_ key: SettingsKey<Value>) -> Bool {
        json[key.rawValue]?.isNull == true
    }
}

extension Settings {
    /// The `--settings` argument: inline JSON without unset keys (a launch
    /// layer starts empty, and the CLI rejects a whole layer holding a
    /// `null`); `nil` when nothing is set.
    var launchArgument: String? {
        let values = json.filter { !$0.value.isNull }
        guard !values.isEmpty, let data = try? JSONEncoder().encode(JSONValue.object(values)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
