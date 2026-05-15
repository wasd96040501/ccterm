import Foundation

/// Controls whether the message send shortcut is Enter or Cmd+Enter.
enum SendKeyBehavior: String, CaseIterable, Identifiable {
    case commandEnter
    case enter

    var id: String { rawValue }

    /// Human-readable label for the Settings picker.
    var title: String {
        switch self {
        case .commandEnter: return String(localized: "⌘Enter to send")
        case .enter: return String(localized: "Enter to send")
        }
    }
}
