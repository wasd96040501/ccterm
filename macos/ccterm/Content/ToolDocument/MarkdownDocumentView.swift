import AppKit
import TranscriptKit

/// Prose a tool produced — a subagent's brief and report, a plan, a task's
/// result — set the way the transcript sets the model's own writing.
@MainActor
final class MarkdownDocumentView: NSView {
    private let transcript = TranscriptView()
    private let rows: [TranscriptRow]
    private var isLoaded = false

    init(markdown: String) {
        rows = [TranscriptRow(id: "body", content: .markdown(markdown))]
        super.init(frame: .zero)
        transcript.translatesAutoresizingMaskIntoConstraints = false
        addSubview(transcript)
        NSLayoutConstraint.activate([
            transcript.topAnchor.constraint(equalTo: topAnchor),
            transcript.leadingAnchor.constraint(equalTo: leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: trailingAnchor),
            transcript.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        transcript.maxContentWidth = 720
        transcript.contentInsets = NSEdgeInsets(top: 16, left: 0, bottom: 24, right: 0)
        transcript.dataSource = self
        transcript.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Mount, lay out, then load (`TranscriptKit` §5): the tab calls this once
    /// it has appeared with its size.
    func load() {
        guard !isLoaded else { return }
        isLoaded = true
        layoutSubtreeIfNeeded()
        transcript.reloadData()
    }
}

extension MarkdownDocumentView: TranscriptViewDataSource {
    func numberOfRows(in transcriptView: TranscriptView) -> Int {
        isLoaded ? rows.count : 0
    }

    func transcriptView(_ transcriptView: TranscriptView, rowAt row: Int) -> TranscriptRow {
        rows[row]
    }
}

extension MarkdownDocumentView: TranscriptViewDelegate {
    func transcriptView(_ transcriptView: TranscriptView, didActivate url: URL, inRow row: Int) {
        NSWorkspace.shared.open(url)
    }
}
