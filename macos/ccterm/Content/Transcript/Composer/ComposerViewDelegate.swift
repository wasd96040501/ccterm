import AppKit

/// What a `ComposerView` reports to its controller: intents only.
@MainActor
protocol ComposerViewDelegate: AnyObject {
    /// The reader sent `text` — a completed command included as `/name words` —
    /// trimmed and not empty; the field is already cleared.
    func composerView(_ composerView: ComposerView, didSubmit text: String)
    /// Stop (the button).
    func composerViewDidRequestStop(_ composerView: ComposerView)
    /// A pull-down was pressed: the controller opens its menu or panel.
    func composerView(_ composerView: ComposerView, didPress control: ComposerView.Control)
    func composerViewDidRequestRestart(_ composerView: ComposerView)
    func composerViewDidRequestLog(_ composerView: ComposerView)
    func composerViewDidRequestWaitingRequest(_ composerView: ComposerView)
    func composerViewDidRequestContextUsage(_ composerView: ComposerView)
    /// The words (or the token) changed.
    func composerViewDidChangeText(_ composerView: ComposerView)
    /// A key the controller decides (completion, ⇧⇥, ⌘.); `true` when it took it.
    func composerView(_ composerView: ComposerView, handle key: ComposerFieldView.Key) -> Bool
}
