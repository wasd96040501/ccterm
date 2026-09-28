import Foundation

public enum PermissionMode: String, Sendable {
    case auto = "auto"
    case `default` = "default"
    case acceptEdits = "acceptEdits"
    case bypassPermissions = "bypassPermissions"
    case plan = "plan"
    case dontAsk = "dontAsk"
}
