import AgentSDK
import Foundation

enum PermissionMode: String, CaseIterable {
    case `default` = "default"
    case acceptEdits = "acceptEdits"
    case plan = "plan"
    case auto = "auto"
    case bypassPermissions = "bypassPermissions"

    /// Long label for the popover row (matches Claude.app's mode menu).
    var title: String {
        switch self {
        case .default: return String(localized: "Ask permissions")
        case .acceptEdits: return String(localized: "Accept edits")
        case .plan: return String(localized: "Plan mode")
        case .auto: return String(localized: "Auto mode")
        case .bypassPermissions: return String(localized: "Bypass permissions")
        }
    }

    /// Short label rendered on the bar's trigger pill.
    var shortTitle: String {
        switch self {
        case .default: return String(localized: "Ask")
        case .acceptEdits: return String(localized: "Edit")
        case .plan: return String(localized: "Plan")
        case .auto: return String(localized: "Auto")
        case .bypassPermissions: return String(localized: "Bypass")
        }
    }

    func toSDK() -> AgentSDK.PermissionMode {
        switch self {
        case .auto: return .auto
        case .default: return .default
        case .acceptEdits: return .acceptEdits
        case .plan: return .plan
        case .bypassPermissions: return .bypassPermissions
        }
    }
}
