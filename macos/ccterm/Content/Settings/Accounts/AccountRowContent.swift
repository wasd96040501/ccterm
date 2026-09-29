import Foundation

/// What an account's row in the list shows, ready to display.
struct AccountRowContent: Equatable {
    var title: String
    /// Under the title: “Claude Max · Personal”, “relay.example.com · opus”.
    var subtitle: String
    /// Claude's mark in front — the subscription's alone.
    var showsMark: Bool

    init(subscription: Subscription) {
        title = subscription.email
        subtitle = [subscription.planName.map { String(localized: "Claude \($0)") }, subscription.organization]
            .compactMap { $0 }.joined(separator: " · ")
        showsMark = true
    }

    init(provider: Account.Provider) {
        title = provider.name
        subtitle = [
            provider.baseURLHost ?? String(localized: "No base URL"),
            provider.models.main.isEmpty ? String(localized: "Default model") : provider.models.main,
        ].joined(separator: " · ")
        showsMark = false
    }
}
