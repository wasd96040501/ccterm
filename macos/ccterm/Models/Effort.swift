import AgentSDK
import Foundation

/// The effort tiers the model picker offers: the CLI's levels plus
/// `ultracode`, which is `xhigh` with the CLI's `ultracode` setting on.
/// Selecting any other tier turns that setting off, so the tiers stay
/// mutually exclusive.
enum Effort: String, CaseIterable {
    case low
    case medium
    case high
    case xhigh
    case max
    case ultracode

    /// The CLI effort level this tier runs at (`--effort`, `effortLevel`).
    var level: AgentSDK.Effort {
        switch self {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        case .xhigh, .ultracode: return .xhigh
        case .max: return .max
        }
    }

    /// The settings that put a session in this tier.
    var settings: AgentSDK.Settings {
        var settings = AgentSDK.Settings()
        settings[.effortLevel] = level
        settings[.ultracode] = self == .ultracode
        return settings
    }

    /// Display label for the effort popover row and the bar's trigger pill.
    /// Effort names mirror the CLI vocabulary and are NOT localized —
    /// translating them obscures the underlying CLI value.
    var title: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        case .max: return "Max"
        case .ultracode: return "Ultracode"
        }
    }
}
