import Foundation

/// What the account sheet reports. The presenter dismisses it.
@MainActor
protocol AccountEditorViewControllerDelegate: AnyObject {
    /// Save or Add, with the draft as it stands.
    func accountEditor(_ editor: AccountEditorViewController, didSave account: Account, secrets: AccountSecrets)
    /// Cancel, Escape or ⌘.
    func accountEditorDidCancel(_ editor: AccountEditorViewController)
    /// Delete… on a provider, or Sign Out… on the subscription — to confirm.
    func accountEditorDidRequestRemoval(_ editor: AccountEditorViewController)
}
