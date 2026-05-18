import AgentSDK
import Foundation

enum PermissionMode: String, CaseIterable {
    case `default` = "default"
    case acceptEdits = "acceptEdits"
    case plan = "plan"
    case auto = "auto"
    case bypassPermissions = "bypassPermissions"

    /// Long label for the popover row (matches Claude.app's mode menu).
    /// Permission-mode names mirror the CLI vocabulary verbatim and are
    /// NOT localized — translating them obscures the underlying CLI flag
    /// the user is toggling.
    var title: String {
        switch self {
        case .default: return "Ask permissions"
        case .acceptEdits: return "Accept edits"
        case .plan: return "Plan mode"
        case .auto: return "Auto mode"
        case .bypassPermissions: return "Bypass permissions"
        }
    }

    /// Short label rendered on the bar's trigger pill. Not localized
    /// (see `title` above).
    var shortTitle: String {
        switch self {
        case .default: return "Ask"
        case .acceptEdits: return "Edit"
        case .plan: return "Plan"
        case .auto: return "Auto"
        case .bypassPermissions: return "Bypass"
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
