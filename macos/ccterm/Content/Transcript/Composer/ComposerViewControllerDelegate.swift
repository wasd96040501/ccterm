import AppKit

/// What a `ComposerViewController` reports: intents only. What sending,
/// stopping or choosing does is the tab's — a New tab changes its draft, a
/// session tab asks the store.
@MainActor
protocol ComposerViewControllerDelegate: AnyObject {
    /// The reader sent `text` (a completed command token included as its
    /// `/name `), trimmed and not empty; the field is cleared.
    func composerViewController(_ composerViewController: ComposerViewController, didSubmit text: String)
    /// Stop (the button, or ⌘.).
    func composerViewControllerDidRequestStop(_ composerViewController: ComposerViewController)
    /// A control's choice — a menu item, the Fast switch, ⇧⇥.
    func composerViewController(
        _ composerViewController: ComposerViewController, didChoose change: SessionSettings.Change)
    /// The failure section's Restart.
    func composerViewControllerDidRequestRestart(_ composerViewController: ComposerViewController)
    /// The failure section's Show Log.
    func composerViewControllerDidRequestLog(_ composerViewController: ComposerViewController)
    /// *Waiting for you ↑* was clicked.
    func composerViewControllerDidRequestWaitingRequest(_ composerViewController: ComposerViewController)
    /// The context ring was clicked.
    func composerViewControllerDidRequestContextUsage(_ composerViewController: ComposerViewController)
}
