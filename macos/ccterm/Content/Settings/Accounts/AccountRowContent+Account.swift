import Components
import Foundation

/// An account's row, worded from the account.
extension AccountRowContent {
    init(subscription: Subscription) {
        self.init(
            title: subscription.email,
            subtitle: [subscription.planName.map { String(localized: "Claude \($0)") }, subscription.organization]
                .compactMap { $0 }.joined(separator: " · "),
            mark: .claude, accessory: .info)
    }

    init(provider: Account.Provider) {
        self.init(
            title: provider.name,
            subtitle: [
                provider.baseURLHost ?? String(localized: "No base URL"),
                provider.models.main.isEmpty ? String(localized: "Default model") : provider.models.main,
            ].joined(separator: " · "),
            mark: .provider, accessory: .info)
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
