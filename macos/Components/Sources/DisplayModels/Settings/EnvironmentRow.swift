import Foundation

/// A row of an account's variable list, ready to display.
public struct EnvironmentRow: Equatable {
    public var isEnabled: Bool
    public var name: String
    /// The value, masked when the name says it is a secret.
    public var displayValue: String
    /// Why the row may not do what it looks like; `nil` when it's fine.
    public var warning: String?

    public init(isEnabled: Bool, name: String, displayValue: String, warning: String?) {
        self.isEnabled = isEnabled
        self.name = name
        self.displayValue = displayValue
        self.warning = warning
    }
}
