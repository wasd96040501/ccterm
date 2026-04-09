import Cocoa
import AgentSDK

enum PermissionMode: String, CaseIterable {
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

    var title: String {
        switch self {
        case .auto: return String(localized: "Auto")
        case .default: return String(localized: "Ask Permission")
        case .acceptEdits: return String(localized: "Accept Edits")
        case .plan: return String(localized: "Plan")
        case .bypassPermissions: return String(localized: "Bypass Permissions")
        }
    }

    var subtitle: String {
        switch self {
        case .auto: return String(localized: "Automatically determine when to ask")
        case .default: return String(localized: "Ask before every tool use")
        case .acceptEdits: return String(localized: "Auto accept file edits only")
        case .plan: return String(localized: "Create plan before making changes")
        case .bypassPermissions: return String(localized: "Skip all permission checks")
        }
    }

    var iconName: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .default: return "hand.raised"
        case .acceptEdits: return "chevron.left.forwardslash.chevron.right"
        case .plan: return "eye"
        case .bypassPermissions: return "lock.open"
        }
    }

    var tintColor: NSColor {
        switch self {
        case .auto: return NSColor(red: 0.58, green: 0.39, blue: 0.82, alpha: 1.0)
        case .default: return .labelColor
        case .acceptEdits: return NSColor(red: 0.36, green: 0.48, blue: 0.85, alpha: 1.0)
        case .plan: return NSColor(red: 0.30, green: 0.64, blue: 0.42, alpha: 1.0)
        case .bypassPermissions: return NSColor(red: 0.85, green: 0.35, blue: 0.35, alpha: 1.0)
        }
    }

    init(from sdk: AgentSDK.PermissionMode) {
        switch sdk {
        case .auto: self = .auto
        case .default: self = .default
        case .acceptEdits: self = .acceptEdits
        case .plan: self = .plan
        case .bypassPermissions, .dontAsk: self = .bypassPermissions
        }
    }

    // MARK: - Persistence

    private static let userDefaultsKey = "permissionMode_"

    static func saved(for path: String) -> PermissionMode {
        guard let raw = UserDefaults.standard.string(forKey: userDefaultsKey + path),
              let mode = PermissionMode(rawValue: raw) else {
            return .default
        }
        return mode
    }

    static func save(_ mode: PermissionMode, for path: String) {
        UserDefaults.standard.set(mode.rawValue, forKey: userDefaultsKey + path)
    }
}
