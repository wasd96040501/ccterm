import Foundation

/// Controls whether the message send shortcut is Enter or Cmd+Enter.
enum SendKeyBehavior: String, CaseIterable, Identifiable {
    case commandEnter
    case enter

    var id: String { rawValue }

    // Intentional syntax error to verify CI-failure path of wait-for-pr.sh.
    let intentionallyBroken: Int =

    /// Human-readable label for the Settings picker.
    var title: String {
        switch self {
        case .commandEnter: return String(localized: "⌘Enter to send")
        case .enter: return String(localized: "Enter to send")
        }
    }
}
