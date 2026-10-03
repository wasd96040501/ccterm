import Foundation

/// A page of the Settings window, in sidebar order.
enum SettingsPane: Int, CaseIterable {
    case general
    case accounts

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .accounts: String(localized: "Accounts")
        }
    }
}
