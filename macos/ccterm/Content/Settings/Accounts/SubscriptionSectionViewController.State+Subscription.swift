import Components
import Foundation

extension SubscriptionSectionViewController.State {
    /// The login as the Subscription section shows it.
    init(_ state: SubscriptionService.State) {
        switch state {
        case .unknown: self = .checking
        case .signedOut: self = .signedOut
        case .signingIn(let url): self = .signingIn(browserURL: url)
        case .signedIn(let subscription): self = .signedIn(AccountRowContent(subscription: subscription))
        }
    }
}
