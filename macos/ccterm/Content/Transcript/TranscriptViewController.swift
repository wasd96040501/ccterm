import AgentSDK
import AppKit
import TranscriptKit

/// One editor tab: a transcript file, read-only, in a `TranscriptView`.
///
/// Loads once, when it first appears and has its size: the file is read off
/// the main actor, the last screen shown at once, and the history prepared
/// off the main actor and prepended behind it a chunk at a time — scroll
/// anchoring keeps the reader's place while it arrives.
@MainActor
final class TranscriptViewController: NSViewController {
    /// The file this tab shows — what the tab is, for finding it again.
    let fileURL: URL

    private let transcript = TranscriptView()
    private var rows: [TranscriptRow] = []
    private var loadTask: Task<Void, Never>?
    private var hasLoaded = false

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

    override func viewDidLoad() {
        super.viewDidLoad()
        transcript.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(transcript)
        NSLayoutConstraint.activate([
            transcript.topAnchor.constraint(equalTo: view.topAnchor),
            transcript.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            transcript.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        transcript.maxContentWidth = 720
        transcript.contentInsets = NSEdgeInsets(top: 12, left: 0, bottom: 24, right: 0)
        transcript.dataSource = self
        transcript.delegate = self
    }

    /// Mount, lay out, then load (`TranscriptKit` §5): here rather than in
    /// `viewWillAppear()`, where a tab's view has no size yet.
    override func viewDidAppear() {
        super.viewDidAppear()
        guard !hasLoaded else { return }
        hasLoaded = true
        view.layoutSubtreeIfNeeded()
        let url = fileURL
        loadTask = Task { [weak self] in
            let rows = await Task.detached(priority: .userInitiated) { Self.rows(contentsOf: url) }.value
            await self?.show(rows)
            self?.loadTask = nil
        }
    }

    /// Stops a load in flight. The editor area calls it before the tab leaves
    /// the tree.
    func prepareForRemoval() {
        loadTask?.cancel()
        loadTask = nil
    }

    // MARK: - Loading

    private nonisolated static func rows(contentsOf url: URL) -> [TranscriptRow] {
        let note: String
        do {
            let rows = TranscriptRow.rows(for: try Transcript(contentsOf: url))
            if !rows.isEmpty { return rows }
            note = String(localized: "This transcript has no messages.")
        } catch {
            note = String(localized: "This transcript couldn’t be read.")
        }
        return [TranscriptRow(id: "note", content: .markdown("*\(note)*"))]
    }

    /// The last screen synchronously, then the history in prepared chunks,
    /// one per hop so the main queue keeps serving everything else.
    private func show(_ all: [TranscriptRow]) async {
        guard !Task.isCancelled else { return }
        var pending = all
        rows = Array(pending.suffix(Self.firstScreenRows))
        pending.removeLast(rows.count)
        transcript.reloadData()
        if !rows.isEmpty { transcript.scrollToRow(at: rows.count - 1, scrollPosition: .bottom) }

        while !pending.isEmpty {
            let chunk = Array(pending.suffix(Self.chunkRows))
            pending.removeLast(chunk.count)
            let prepared = await transcript.prepareRows(chunk)
            guard !Task.isCancelled else { return }
            // No suspension between changing the rows and announcing it.
            rows.insert(contentsOf: chunk, at: 0)
            transcript.insertRows(at: IndexSet(0..<chunk.count), warming: prepared)
            await Task.yield()
        }
    }

    /// Enough to fill a tall window; the point is that it is small.
    private static let firstScreenRows = 30

    /// The unit of work a cancellation throws away.
    private static let chunkRows = 300
}

extension TranscriptViewController: TranscriptViewDataSource {
    func numberOfRows(in transcriptView: TranscriptView) -> Int {
        rows.count
    }

    func transcriptView(_ transcriptView: TranscriptView, rowAt row: Int) -> TranscriptRow {
        rows[row]
    }
}

extension TranscriptViewController: TranscriptViewDelegate {
    func transcriptView(_ transcriptView: TranscriptView, didActivate url: URL, inRow row: Int) {
        NSWorkspace.shared.open(url)
    }
}
