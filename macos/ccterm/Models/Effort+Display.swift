import AgentSDK
import Foundation

extension AgentSDK.Effort {
    /// Display label for the effort popover row and the bar's trigger pill.
    var title: String {
        switch self {
        case .low: return String(localized: "Low")
        case .medium: return String(localized: "Medium")
        case .high: return String(localized: "High")
        case .max: return String(localized: "Max")
        }
    }
}
