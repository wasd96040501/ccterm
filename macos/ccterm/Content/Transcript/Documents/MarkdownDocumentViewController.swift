import AppKit
import TranscriptKit

/// A document that is words: a `TranscriptView` of markdown rows, the same
/// renderer as the transcript's replies — no second renderer.
@MainActor
final class MarkdownDocumentViewController: NSViewController {
    private let markdown: String

    init(markdown: String) {
        self.markdown = markdown
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = NSView()
    }
}
