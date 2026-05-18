import AgentSDK
import Foundation

extension AgentSDK.Effort {
    /// Display label for the effort popover row and the bar's trigger
    /// pill. Effort-level names mirror the CLI vocabulary and are NOT
    /// localized — translating them obscures the underlying CLI value.
    var title: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        case .max: return "Max"
        }
    }
}
