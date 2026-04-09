import Cocoa
import AgentSDK

extension Effort: @retroactive CaseIterable {
    public static var allCases: [Effort] { [.low, .medium, .high, .max] }
}

extension Effort {

    var iconName: String {
        switch self {
        case .low:    return "gauge.with.dots.needle.0percent"
        case .medium: return "gauge.with.dots.needle.33percent"
        case .high:   return "gauge.with.dots.needle.67percent"
        case .max:    return "gauge.with.dots.needle.100percent"
        }
    }

    /// Normalized gauge value: 0.0 (low) … 1.0 (max)
    var gaugeValue: Double {
        switch self {
        case .low:    return 0.0
        case .medium: return 0.33
        case .high:   return 0.67
        case .max:    return 1.0
        }
    }

    var title: String {
        switch self {
        case .low:    return String(localized: "Low")
        case .medium: return String(localized: "Medium")
        case .high:   return String(localized: "High")
        case .max:    return String(localized: "Max")
        }
    }

    var tintColor: NSColor {
        switch self {
        case .low:    return NSColor(red: 0.40, green: 0.72, blue: 0.55, alpha: 1.0)
        case .medium: return NSColor(red: 0.36, green: 0.48, blue: 0.85, alpha: 1.0)
        case .high:   return NSColor(red: 0.90, green: 0.65, blue: 0.25, alpha: 1.0)
        case .max:    return NSColor(red: 0.85, green: 0.35, blue: 0.35, alpha: 1.0)
        }
    }
}
