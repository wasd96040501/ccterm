import Foundation

/// What the person asked of the subscription section.
@MainActor
public protocol SubscriptionSectionViewControllerDelegate: AnyObject {
    /// ⓘ, a double click or Details… on the signed-in account — there is at
    /// most one.
    func subscriptionSectionDidRequestOpen(_ section: SubscriptionSectionViewController)
    func subscriptionSectionDidRequestSignIn(_ section: SubscriptionSectionViewController)
    /// Cancel in the sign-in sheet, however it was closed.
    func subscriptionSectionDidCancelSignIn(_ section: SubscriptionSectionViewController)
    /// Sign Out… from the row's menu — to confirm.
    func subscriptionSectionDidRequestSignOut(_ section: SubscriptionSectionViewController)
}
