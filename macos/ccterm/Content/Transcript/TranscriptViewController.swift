import AgentSDK
import AppKit
import TranscriptKit

/// One editor tab: a transcript file, read-only, in a `TranscriptView`.
///
/// What the model and the user wrote are the transcript's own rows; tool
/// calls, local commands and notices are cards the app draws (`.view` rows,
/// `Cards/`). A card never shows detail itself — it asks, through the
/// delegate, for a document to open beside the transcript.
///
/// Loads once, when it first appears and has its size: the file is read off
/// the main actor, the last screen shown at once, and the history prepared
/// off the main actor and prepended behind it a chunk at a time — scroll
/// anchoring keeps the reader's place while it arrives.
@MainActor
final class TranscriptViewController: NSViewController {
    /// The file this tab shows — what the tab is, for finding it again.
    let fileURL: URL

    weak var delegate: TranscriptViewControllerDelegate?

    private let transcript = TranscriptView()
    private var rows: [TranscriptRow] = []
    /// Every card of the transcript, shown or still to be prepended.
    private var cards: [TranscriptRow.ID: TranscriptCard] = [:]
    /// The tool groups the reader opened.
    private var expanded = Set<TranscriptRow.ID>()
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
            let outline = await Task.detached(priority: .userInitiated) { Self.outline(contentsOf: url) }.value
            await self?.show(outline)
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

    private nonisolated static func outline(contentsOf url: URL) -> TranscriptOutline {
        let note: String
        do {
            let outline = TranscriptOutline(try Transcript(contentsOf: url), source: url)
            if !outline.rows.isEmpty { return outline }
            note = String(localized: "This transcript has no messages.")
        } catch {
            note = String(localized: "This transcript couldn’t be read.")
        }
        return TranscriptOutline(rows: [TranscriptRow(id: "note", content: .markdown("*\(note)*"))])
    }

    /// The last screen synchronously, then the history in prepared chunks,
    /// one per hop so the main queue keeps serving everything else.
    private func show(_ outline: TranscriptOutline) async {
        guard !Task.isCancelled else { return }
        cards = outline.cards
        var pending = outline.rows
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

    func transcriptView(_ transcriptView: TranscriptView, heightOfRow row: Int, width: CGFloat) -> CGFloat {
        let id = rows[row].id
        switch cards[id] {
        case .tools(let group)?: return ToolGroupView.height(for: group, expanded: expanded.contains(id))
        case .notice?: return NoticeView.height
        case .command(let command)?: return LocalCommandView.height(for: command)
        case nil: return 0
        }
    }

    func transcriptView(_ transcriptView: TranscriptView, viewForRow row: Int) -> NSView {
        let id = rows[row].id
        switch cards[id] {
        case .tools(let group)?:
            let view = transcriptView.makeView(withIdentifier: .toolGroup) { ToolGroupView() }
            view.delegate = self
            view.configure(with: group, expanded: expanded.contains(id))
            return view
        case .notice(let notice)?:
            let view = transcriptView.makeView(withIdentifier: .notice) { NoticeView() }
            view.delegate = self
            view.configure(with: notice)
            return view
        case .command(let command)?:
            let view = transcriptView.makeView(withIdentifier: .localCommand) { LocalCommandView() }
            view.delegate = self
            view.configure(with: command)
            return view
        case nil:
            return transcriptView.makeView(withIdentifier: .emptyCard) { NSView() }
        }
    }
}

extension TranscriptViewController: TranscriptCardDelegate {
    /// Opens or closes the group the card serves now, wherever that is.
    func cardDidToggle(_ card: NSView) {
        let row = transcript.row(for: card)
        guard rows.indices.contains(row), case .tools(let group)? = cards[rows[row].id] else { return }
        let id = rows[row].id
        let isExpanded = !expanded.contains(id)
        if isExpanded { expanded.insert(id) } else { expanded.remove(id) }
        (card as? ToolGroupView)?.configure(with: group, expanded: isExpanded, animated: true)
        transcript.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
    }

    func card(_ card: NSView, open document: ToolDocument, pinned: Bool) {
        delegate?.transcriptViewController(self, open: document, pinned: pinned)
    }
}

extension NSUserInterfaceItemIdentifier {
    fileprivate static let toolGroup = Self("TranscriptViewController.toolGroup")
    fileprivate static let notice = Self("TranscriptViewController.notice")
    fileprivate static let localCommand = Self("TranscriptViewController.localCommand")
    fileprivate static let emptyCard = Self("TranscriptViewController.emptyCard")
}
