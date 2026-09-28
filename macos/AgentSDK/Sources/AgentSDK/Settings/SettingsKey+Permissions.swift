import Foundation

// Permission and hook settings.

extension SettingsKey where Value == PermissionSettings {
    /// Permission rules, the default mode and extra directories. Replaced as
    /// a whole when applied; see ``PermissionSettings``.
    public static var permissions: Self { Self("permissions") }
}

extension SettingsKey where Value == JSONValue {
    /// Hook commands keyed by event (`PreToolUse`, `Stop`, …), in the
    /// `settings.json` hooks format.
    public static var hooks: Self { Self("hooks") }
}

extension SettingsKey where Value == Bool {
    /// Turns off every hook and the status line command.
    public static var disableAllHooks: Self { Self("disableAllHooks") }
}
