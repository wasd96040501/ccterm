import AppKit
import TranscriptKit

/// One editor tab: a transcript file, read-only, in a `TranscriptView`.
///
/// Loads once, when it first appears and has its size: the last screen at
/// once, then the history prepared off the main actor and prepended behind
/// it.
@MainActor
final class TranscriptViewController: NSViewController {
    /// The file this tab shows — what the tab is, for finding it again.
    let fileURL: URL

    private let transcript = TranscriptView()

    init(fileURL: URL, title: String) {
        self.fileURL = fileURL
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = NSView()
    }

    /// Stops a load in flight. The editor area calls it before the tab leaves
    /// the tree.
    func prepareForRemoval() {}
}
