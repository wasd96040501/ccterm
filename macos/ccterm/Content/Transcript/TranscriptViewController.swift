import AgentSDK
import AppKit
import TranscriptKit

/// One editor tab: a transcript file, read-only, in a `TranscriptView`.
///
/// Loads once, when it first appears and has its size: the transcript comes
/// from the injected `load` and becomes a `TranscriptPage` off the main
/// actor; the last screen of its rows is shown at once, and the history
/// prepended behind it a chunk at a time — scroll anchoring keeps the
/// reader's place while it arrives.
///
/// Owns what the reader does to the page: which runs are open
/// (`RunDisclosure`), which item's document is showing (the selection,
/// stepped with ↑ / ↓), and bringing an item back into view. What opening
/// a document does is the delegate's.
@MainActor
final class TranscriptViewController: NSViewController {
    /// The file this tab shows — what the tab is, for finding it again.
    let fileURL: URL

    /// Reads a transcript; `LibraryStore.transcript(at:)`.
    typealias Load = @Sendable (URL) async throws -> Transcript

    weak var delegate: TranscriptViewControllerDelegate?

    private let load: Load
    private let transcript = TranscriptView()
    private var page = TranscriptPage(entries: [])
    /// The rows the transcript shows, in order — the data source's answer.
    private var rows: [PageRow] = []
    /// Runs and news rows the reader opened, by entry id; absent is collapsed.
    private var disclosure: [String: RunDisclosure] = [:]
    /// The id whose document is showing beside (`PageRow.opens`).
    private var selection: String?
    /// The id brought back into view just now, flashing once.
    private var flashing: String?
    private var loadTask: Task<Void, Never>?
    private var hasLoaded = false

    init(fileURL: URL, title: String, load: @escaping Load) {
        self.fileURL = fileURL
        self.load = load
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
        let (url, load) = (fileURL, load)
        loadTask = Task { [weak self] in
            let page = await Task.detached(priority: .userInitiated) { await Self.page(url, load) }.value
            await self?.show(page)
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

    private nonisolated static func page(_ url: URL, _ load: Load) async -> TranscriptPage {
        let note: String
        do {
            let page = TranscriptPage(try await load(url))
            if !page.entries.isEmpty { return page }
            note = String(localized: "This transcript has no messages.")
        } catch {
            note = String(localized: "This transcript couldn’t be read.")
        }
        return TranscriptPage(entries: [.reply(id: "note", markdown: "*\(note)*")])
    }

    /// The last screen synchronously, then the history in prepared chunks,
    /// one per hop so the main queue keeps serving everything else.
    private func show(_ page: TranscriptPage) async {
        guard !Task.isCancelled else { return }
        self.page = page
        var pending = PageRow.rows(for: page)
        rows = Array(pending.suffix(Self.firstScreenRows))
        pending.removeLast(rows.count)
        transcript.reloadData()
        if !rows.isEmpty { transcript.scrollToRow(at: rows.count - 1, scrollPosition: .bottom) }

        while !pending.isEmpty {
            let chunk = Array(pending.suffix(Self.chunkRows))
            pending.removeLast(chunk.count)
            // `.view` rows are measured by their static height; only the
            // markdown is worth a trip off the main actor.
            let prepared = await transcript.prepareRows(
                chunk.map(\.transcriptRow).filter { $0.content != .view })
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

    // MARK: - Disclosure

    private func disclosure(of entryID: String) -> RunDisclosure {
        disclosure[entryID] ?? .collapsed
    }

    /// Shows entry `entryID`'s rows as `newValue` discloses them: its first
    /// row stays and is reloaded (its chevron turns), the rest are swapped.
    ///
    /// The first row holds still on screen and the rows below it open or close
    /// a gap, as an outline view discloses; inside a caller's batch the
    /// caller's anchor wins.
    private func setDisclosure(_ newValue: RunDisclosure, of entryID: String) {
        guard let entryIndex = page.entryIndex(containing: entryID), page.entries[entryIndex].id == entryID
        else { return }
        disclosure[entryID] = newValue == .collapsed ? nil : newValue
        // Rows not shown yet arrive collapsed with their chunk.
        guard let first = rows.firstIndex(where: { $0.id.entry == entryID }) else { return }
        let end = rows[first...].firstIndex { $0.id.entry != entryID } ?? rows.endIndex
        let replacement = PageRow.rows(for: page.entries[entryIndex], disclosure: newValue)
        rows.replaceSubrange(first..<end, with: replacement)
        transcript.performBatchUpdates(anchoring: .row(first)) {
            if end - first > 1 {
                transcript.removeRows(at: IndexSet(first + 1..<end), withAnimation: .effectGap)
            }
            if replacement.count > 1 {
                transcript.insertRows(
                    at: IndexSet(first + 1..<first + replacement.count), withAnimation: .effectGap)
            }
            transcript.reloadRows(at: IndexSet(integer: first))
        }
    }

    /// Every run and news row that has a list to open.
    private var disclosableEntries: [String] {
        page.entries.compactMap { entry in
            switch entry {
            case .run(let run) where !run.isSingle: run.id
            case .news(let news) where !news.isSingle: news.id
            default: nil
            }
        }
    }

    // MARK: - Selection

    /// Marks `id` as the item whose document is showing, and redraws the
    /// rows that gain or lose the highlight.
    private func select(_ id: String?, flashing: Bool = false) {
        let changed = [selection, self.flashing, id].compactMap { $0 }
        selection = id
        self.flashing = flashing ? id : nil
        let indexes = IndexSet(changed.compactMap { id in rows.firstIndex { $0.opens == id } })
        if !indexes.isEmpty { transcript.reloadRows(at: indexes) }
    }

    /// Opens `id` beside the transcript, as the reader asked.
    private func open(_ id: String, pinned: Bool) {
        select(id)
        guard let document = page.document(DocumentReference(transcriptURL: fileURL, id: id)) else { return }
        delegate?.transcriptViewController(self, open: document, pinned: pinned)
    }

    /// ↑ / ↓ from the selected item to the next row that opens something,
    /// whose document follows.
    private func step(by offset: Int) -> Bool {
        guard let selection, let current = rows.firstIndex(where: { $0.opens == selection }) else { return false }
        var index = current + offset
        while rows.indices.contains(index) {
            if let id = rows[index].opens {
                open(id, pinned: false)
                transcript.scrollToRow(at: index, scrollPosition: .nearestEdge)
                return true
            }
            index += offset
        }
        return true
    }

    /// Brings `id` — an item, or the call an entry is about — into view and
    /// flashes it, opening the run it is in. `select` marks it as the item
    /// whose document is showing (*Show in Transcript*); otherwise the run is
    /// closed again after the flash, as it was (↖ on news).
    func reveal(_ id: String, select selecting: Bool) {
        guard let entryIndex = page.entryIndex(containing: id) else { return }
        let entryID = page.entries[entryIndex].id
        // A run's id is its first item's too: in a run with a list, an id is
        // always an item.
        let opened = disclosure(of: entryID) == .collapsed && disclosableEntries.contains(entryID)
        if opened { setDisclosure(.expanded, of: entryID) }
        if disclosure(of: entryID) == .expanded, !rows.contains(where: { $0.opens == id }) {
            setDisclosure(.showingAll, of: entryID)
        }
        guard let row = rows.firstIndex(where: { $0.opens == id }) ?? rows.firstIndex(where: { $0.id.entry == entryID })
        else { return }
        transcript.scrollToRow(at: row, scrollPosition: .center)
        if selecting {
            select(id, flashing: true)
        } else {
            flashing = id
            transcript.reloadRows(at: IndexSet(integer: row))
        }
        Task { [weak self] in
            try? await Task.sleep(for: Self.flashDuration)
            guard let self, self.flashing == id else { return }
            self.flashing = nil
            if opened, !selecting { self.setDisclosure(.collapsed, of: entryID) }
        }
    }

    /// How long a revealed row flashes before a run opened for it closes.
    private static let flashDuration = Duration.milliseconds(1200)
}

extension TranscriptViewController: TranscriptViewDataSource {
    func numberOfRows(in transcriptView: TranscriptView) -> Int {
        rows.count
    }

    func transcriptView(_ transcriptView: TranscriptView, rowAt row: Int) -> TranscriptRow {
        rows[row].transcriptRow
    }
}

extension TranscriptViewController: TranscriptViewDelegate {
    func transcriptView(_ transcriptView: TranscriptView, heightOfRow row: Int, width: CGFloat) -> CGFloat {
        rows[row].height(width: width)
    }

    func transcriptView(_ transcriptView: TranscriptView, customSpacingAboveRow row: Int) -> CGFloat? {
        rows[row].spacingAbove
    }

    func transcriptView(_ transcriptView: TranscriptView, viewForRow row: Int) -> NSView {
        let pageRow = rows[row]
        let opens = pageRow.opens
        return pageRow.makeView(
            in: transcriptView, isSelected: opens != nil && opens == selection,
            flashes: opens != nil && opens == flashing, delegate: self)
    }

    func transcriptView(_ transcriptView: TranscriptView, didActivate url: URL, inRow row: Int) {
        NSWorkspace.shared.open(url)
    }

    func transcriptView(_ transcriptView: TranscriptView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): step(by: -1)
        case #selector(NSResponder.moveDown(_:)): step(by: 1)
        default: false
        }
    }
}

extension TranscriptViewController: PageRowViewDelegate {
    func rowView(_ rowView: NSView, open id: String, pinned: Bool) {
        open(id, pinned: pinned)
    }

    func rowView(_ rowView: NSView, toggle runID: String, all: Bool) {
        let newValue: RunDisclosure = disclosure(of: runID) == .collapsed ? .expanded : .collapsed
        // One batch, holding the row that was clicked, so the whole change is
        // one motion around it.
        let clicked = transcript.row(for: rowView)
        transcript.performBatchUpdates(anchoring: clicked >= 0 ? .row(clicked) : .automatic) {
            for entryID in all ? disclosableEntries : [runID] {
                setDisclosure(newValue, of: entryID)
            }
        }
    }

    func rowView(_ rowView: NSView, showAllOf runID: String) {
        setDisclosure(.showingAll, of: runID)
    }

    func rowView(_ rowView: NSView, revealOrigin callID: String) {
        reveal(callID, select: false)
    }

    /// Answering a call is not wired to a live session yet.
    func rowView(_ rowView: NSView, decide decision: Decision, for callID: String) {
        appLog(.info, "TranscriptViewController", "decision \(decision) for \(callID) — no live session")
    }
}
