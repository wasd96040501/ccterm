import AppKit
import TranscriptKit

/// A document that is words: a `TranscriptView` of markdown rows, the same
/// renderer as the transcript's replies — no second renderer. Its one row is
/// the whole markdown, so find, selection and copy work as in a reply.
@MainActor
final class MarkdownDocumentViewController: NSViewController {
    private let markdown: String
    private let transcript = TranscriptView()
    private var hasLoaded = false

    init(markdown: String) {
        self.markdown = markdown
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Mounted with its constraints here; loaded once it has its size
    /// (`viewDidAppear`) — `TranscriptKit` §5 "How a host loads".
    override func loadView() {
        view = NSView()
        transcript.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(transcript)
        NSLayoutConstraint.activate([
            transcript.topAnchor.constraint(equalTo: view.topAnchor),
            transcript.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            transcript.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        transcript.maxContentWidth = 720
        transcript.contentInsets = NSEdgeInsets(top: 20, left: 0, bottom: 28, right: 0)
        transcript.dataSource = self
        transcript.delegate = self
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !hasLoaded else { return }
        hasLoaded = true
        view.layoutSubtreeIfNeeded()
        transcript.reloadData()
    }
}

extension MarkdownDocumentViewController: TranscriptViewDataSource {
    func numberOfRows(in transcriptView: TranscriptView) -> Int {
        hasLoaded ? 1 : 0
    }

    func transcriptView(_ transcriptView: TranscriptView, rowAt row: Int) -> TranscriptRow {
        TranscriptRow(id: "markdown", content: .markdown(markdown))
    }
}

extension MarkdownDocumentViewController: TranscriptViewDelegate {
    func transcriptView(_ transcriptView: TranscriptView, didActivate url: URL, inRow row: Int) {
        NSWorkspace.shared.open(url)
    }
}
