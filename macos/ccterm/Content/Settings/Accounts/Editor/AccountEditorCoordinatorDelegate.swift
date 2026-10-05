import Foundation

/// How an account's sheet ended, or asks to. The presenter dismisses it.
@MainActor
protocol AccountEditorCoordinatorDelegate: AnyObject {
    /// Save or Add, with the draft as it stands.
    func accountEditor(_ editor: AccountEditorCoordinator, didSave account: Account, secrets: AccountSecrets)
    /// Cancel, Escape or ⌘.
    func accountEditorDidCancel(_ editor: AccountEditorCoordinator)
    /// Delete… on a provider, or Sign Out… on the subscription — to confirm.
    func accountEditorDidRequestRemoval(_ editor: AccountEditorCoordinator)
}
