import Foundation

/// What an account's row in the list shows, ready to display.
public struct AccountRowContent: Equatable {
    public var title: String
    /// Under the title: “Claude Max · Personal”, “relay.example.com · opus”.
    public var subtitle: String
    public var mark: Mark
    public var accessory: Accessory

    /// What stands in front of the title, 28 square.
    public enum Mark: Equatable {
        case none
        case claude
        /// Greyed, while no one is signed in.
        case claudeDimmed
        /// Every API provider's: `server.rack`.
        case provider
    }

    /// What sits at the row's trailing edge.
    public enum Accessory: Equatable {
        /// ⓘ, opening the account.
        case info
        /// A push button with this title.
        case button(String)
        /// A spinner, while the row's state is being read.
        case progress
    }

    public init(title: String, subtitle: String, mark: Mark, accessory: Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.mark = mark
        self.accessory = accessory
    }
}
