import DisplayModels
import Foundation

extension SidebarActivity {
    /// What VoiceOver says of a mark.
    var accessibilityLabel: String {
        switch self {
        case .idle: String(localized: "Idle", bundle: .module)
        case .responding: String(localized: "Responding", bundle: .module)
        case .needsInput: String(localized: "Needs Your Input", bundle: .module)
        case .failed: String(localized: "Failed", bundle: .module)
        }
    }
}
