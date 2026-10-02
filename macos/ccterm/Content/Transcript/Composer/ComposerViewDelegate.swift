import AppKit

/// What a `ComposerView` reports.
@MainActor
protocol ComposerViewDelegate: AnyObject {
    /// The reader sent `text`, already trimmed and not empty; the field is
    /// cleared.
    func composerView(_ composerView: ComposerView, didSubmit text: String)
    /// The reader pressed *Stop*.
    func composerViewDidRequestStop(_ composerView: ComposerView)
}
