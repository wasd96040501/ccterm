import Foundation

/// What an account's row in the list shows, ready to display.
struct AccountRowContent: Equatable {
    var title: String
    /// Under the title: “Claude Max · Personal”, “relay.example.com · opus”.
    var subtitle: String
    var mark: Mark
    var accessory: Accessory

    /// What stands in front of the title, 28 square.
    enum Mark: Equatable {
        case none
        case claude
        /// Greyed, while no one is signed in.
        case claudeDimmed
        /// Every API provider's: `server.rack`.
        case provider
    }

    /// What sits at the row's trailing edge.
    enum Accessory: Equatable {
        /// ⓘ, opening the account.
        case info
        /// A push button with this title.
        case button(String)
        /// A spinner, while the row's state is being read.
        case progress
    }

    init(title: String, subtitle: String, mark: Mark, accessory: Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.mark = mark
        self.accessory = accessory
    }

    init(subscription: Subscription) {
        title = subscription.email
        subtitle = [subscription.planName.map { String(localized: "Claude \($0)") }, subscription.organization]
            .compactMap { $0 }.joined(separator: " · ")
        mark = .claude
        accessory = .info
    }

    init(provider: Account.Provider) {
        title = provider.name
        subtitle = [
            provider.baseURLHost ?? String(localized: "No base URL"),
            provider.models.main.isEmpty ? String(localized: "Default model") : provider.models.main,
        ].joined(separator: " · ")
        mark = .provider
        accessory = .info
    }

    /// No one is signed in to a subscription.
    static let signedOut = AccountRowContent(
        title: String(localized: "Not signed in"), subtitle: String(localized: "Use your Claude Pro or Max plan."),
        mark: .claudeDimmed, accessory: .button(String(localized: "Sign In…")))

    /// The login hasn't been read yet.
    static let checking = AccountRowContent(
        title: String(localized: "Subscription"), subtitle: String(localized: "Checking…"), mark: .claudeDimmed,
        accessory: .progress)
}
