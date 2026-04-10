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

    /// Tooltip text for the send button.
    var shortcutHint: String {
        switch self {
        case .commandEnter: return String(localized: "Command Enter (⌘↩)")
        case .enter: return String(localized: "Enter (↩)")
        }
    }

    /// Placeholder for the chat input: "⌘Enter to send" or "Enter to send".
    var sendPlaceholder: String {
        switch self {
        case .commandEnter: return String(localized: "⌘Enter to send")
        case .enter: return String(localized: "Enter to send")
        }
    }

    /// Placeholder for the chat input in queue mode.
    var queuePlaceholder: String {
        switch self {
        case .commandEnter: return String(localized: "⌘Enter to queue")
        case .enter: return String(localized: "Enter to queue")
        }
    }

    /// Placeholder for the comment input.
    var commentPlaceholder: String {
        switch self {
        case .commandEnter: return String(localized: "⌘Enter to comment")
        case .enter: return String(localized: "Enter to comment")
        }
    }

    /// Placeholder for the deny-with-feedback input.
    var denyFeedbackPlaceholder: String {
        switch self {
        case .commandEnter: return String(localized: "⌘Enter to deny with feedback")
        case .enter: return String(localized: "Enter to deny with feedback")
        }
    }

    /// Placeholder when no directory is set.
    var temporarySessionPlaceholder: String {
        switch self {
        case .commandEnter: return String(localized: "@ Select directory · ⌘Enter temporary session")
        case .enter: return String(localized: "@ Select directory · Enter temporary session")
        }
    }
}
