import Foundation

/// What the person asked of the subscription section.
@MainActor
protocol SubscriptionSectionViewControllerDelegate: AnyObject {
    /// ⓘ, a double click or Details… on the signed-in account.
    func subscriptionSection(_ section: SubscriptionSectionViewController, didOpen subscription: Subscription)
    func subscriptionSectionDidRequestSignIn(_ section: SubscriptionSectionViewController)
    /// Cancel in the sign-in sheet, however it was closed.
    func subscriptionSectionDidCancelSignIn(_ section: SubscriptionSectionViewController)
    /// Sign Out… from the row's menu — to confirm.
    func subscriptionSection(_ section: SubscriptionSectionViewController, didRequestSignOut subscription: Subscription)
}
