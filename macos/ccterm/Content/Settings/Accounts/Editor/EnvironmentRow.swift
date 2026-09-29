import Foundation

/// A row of an account's variable list, ready to display.
struct EnvironmentRow: Equatable {
    var isEnabled: Bool
    var name: String
    /// The value, masked when the name says it is a secret.
    var displayValue: String
    /// Why the row may not do what it looks like; `nil` when it's fine.
    var warning: String?
}
