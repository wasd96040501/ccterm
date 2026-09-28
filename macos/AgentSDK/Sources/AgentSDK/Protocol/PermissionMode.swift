import Foundation

/// How the CLI decides whether a tool call may run (`--permission-mode`,
/// `permissions.defaultMode` in settings).
public enum PermissionMode: String, Sendable, SettingsValue {
    case auto = "auto"
    case `default` = "default"
    case acceptEdits = "acceptEdits"
    case bypassPermissions = "bypassPermissions"
    case plan = "plan"
    case dontAsk = "dontAsk"
}
