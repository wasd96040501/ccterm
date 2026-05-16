import AgentSDK
import Foundation

enum PermissionMode: String {
    case `default` = "default"
    case acceptEdits = "acceptEdits"
    case plan = "plan"
    case auto = "auto"
    case bypassPermissions = "bypassPermissions"

    /// 映射到 AgentSDK PermissionMode。
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
