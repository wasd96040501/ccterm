import Foundation

/// A Claude Code setting — a top-level `settings.json` key — together with
/// the type of its value.
///
/// Keys are an open set, like `NSAttributedString.Key`: the SDK defines the
/// common ones as static members (``effortLevel``, ``permissions``, …) and a
/// consumer adds any other the same way. A static member lives in an
/// extension constrained to its value type, so a value of the wrong type
/// does not compile:
///
/// ```swift
/// extension SettingsKey where Value == Bool {
///     static var spinnerTipsEnabled: Self { Self("spinnerTipsEnabled") }
/// }
///
/// var settings = Settings()
/// settings[.spinnerTipsEnabled] = false
/// ```
///
/// Name the member after the `settings.json` key with Swift casing for
/// acronyms (`promptCacheTtl` → ``promptCacheTTL``). A key whose value has
/// no Swift model yet takes `JSONValue` as its value type (see ``hooks``).
public struct SettingsKey<Value: SettingsValue>: Hashable, Sendable {
    /// The key as written in `settings.json`.
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}
