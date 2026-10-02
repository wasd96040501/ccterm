import AgentSDK
import AppKit
import TranscriptKit

/// One editor tab: a session's transcript in a `TranscriptView`, and — for a
/// session's own tab — the composer under it.
///
/// Follows the session from when it first appears and has its size
/// (`SessionStore.states(at:)`): each state becomes a `TranscriptPage` off
/// the main actor. The first page shows its last screen of rows at once and
/// prepends the history behind it a chunk at a time — scroll anchoring keeps
/// the reader's place while it arrives; every later page (a live session's)
/// is applied as the changes from the rows shown (`PageRow.changes`). The
/// next state is pulled only once a page is shown, and only the newest
/// waits, so a live page never lands on a half-shown first one.
///
/// Owns what the reader does to the page: which runs are open
/// (`RunDisclosure`), which item's document is showing (the selection), and
/// bringing an item back into view. What opening a document does is the
/// delegate's; what sending, stopping and answering do is the store's.
@MainActor
final class TranscriptViewController: NSViewController {
    /// The file this tab shows — what the tab is, for finding it again.
    let fileURL: URL

    weak var delegate: TranscriptTabDelegate?

    private let sessions: SessionStore
    private let transcript = TranscriptView()
    /// The composer, on a session's own tab; a subagent's conversation has
    /// none — nothing can be sent to it.
    private let composer: ComposerView?
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

    /// `acceptsInput`: whether the tab has a composer — a session's own tab,
    /// not a subagent's conversation.
    init(fileURL: URL, title: String, sessions: SessionStore, acceptsInput: Bool) {
        self.fileURL = fileURL
        self.sessions = sessions
        composer = acceptsInput ? ComposerView() : nil
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
        ])
        if let composer {
            composer.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(composer)
            NSLayoutConstraint.activate([
                composer.topAnchor.constraint(equalTo: transcript.bottomAnchor),
                composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                composer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            composer.delegate = self
        } else {
            transcript.bottomAnchor.constraint(equalTo: view.bottomAnchor).isActive = true
        }
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
        let states = sessions.states(at: fileURL)
        loadTask = Task { [weak self] in
            var first = true
            do {
                for try await state in states {
                    let page = await Task.detached(priority: .userInitiated) { Self.page(state) }.value
                    guard let self, !Task.isCancelled else { return }
                    composer?.configure(isResponding: state.isResponding)
                    if first {
                        first = false
                        await show(page)
                        // A session just made is empty and live: ready to type.
                        if state.isLive, page.entries.isEmpty { composer?.focus() }
                    } else {
                        apply(page)
                    }
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                await show(Self.note(String(localized: "This transcript couldn’t be read.")))
            }
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

    /// The page of `state`; a transcript at rest with nothing on it says so —
    /// a live one is just empty until the first prompt.
    private nonisolated static func page(_ state: SessionState) -> TranscriptPage {
        let page = TranscriptPage(state.transcript, partial: state.partial, requests: state.requests)
        if page.entries.isEmpty, !state.isLive {
            return note(String(localized: "This transcript has no messages."))
        }
        return page
    }

    private nonisolated static func note(_ note: String) -> TranscriptPage {
        TranscriptPage(entries: [.reply(id: "note", markdown: "*\(note)*")])
    }

    /// Shows a later page of a live session: the changes from the rows shown,
    /// in one batch, the reader's disclosure kept.
    private func apply(_ page: TranscriptPage) {
        self.page = page
        let new = page.entries.flatMap { PageRow.rows(for: $0, disclosure: disclosure(of: $0.id)) }
        let changes = PageRow.changes(from: rows, to: new)
        guard !changes.isEmpty else { return }
        // No suspension between changing the rows and announcing it. The
        // transcript holds the reader's place itself: at the bottom it stays
        // at the bottom as rows arrive and grow, anywhere else the rows in
        // view hold still. Selection and flashing are ids, so the rows that
        // keep them are reloaded under the same marks.
        rows = new
        transcript.performBatchUpdates {
            if !changes.removed.isEmpty { transcript.removeRows(at: changes.removed) }
            if !changes.inserted.isEmpty { transcript.insertRows(at: changes.inserted) }
            if !changes.reloaded.isEmpty { transcript.reloadRows(at: changes.reloaded) }
        }
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
            transcript.insertRows(at: IndexSet(0..<chunk.count), prepared: prepared)
            // The row that was first has one above it now, and its gap depends on it.
            transcript.noteHeightOfRows(withIndexesChanged: IndexSet(integer: chunk.count))
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
        guard let delegate else { return }
        let sessions = sessions
        delegate.transcriptTab(
            self, didRequestOpen: .document(document.reference), pinned: pinned,
            makeItem: { TranscriptTab.makeItem(document, sessions: sessions, delegate: delegate) })
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
        rows[row].spacingAbove(after: row > 0 ? rows[row - 1] : nil)
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
}

extension TranscriptViewController: PageRowViewDelegate {
    func pageRowView(_ rowView: NSView, didRequestDocument id: String, pinned: Bool) {
        open(id, pinned: pinned)
    }

    func pageRowView(_ rowView: NSView, didToggleDisclosureOf runID: String, inAllRuns all: Bool) {
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

    func pageRowView(_ rowView: NSView, didRequestAllItemsOf runID: String) {
        setDisclosure(.showingAll, of: runID)
    }

    func pageRowView(_ rowView: NSView, didRequestOriginOf callID: String) {
        reveal(callID, select: false)
    }

    func pageRowView(_ rowView: NSView, didDecide decision: Decision, forCall callID: String) {
        decide(decision, forCall: callID)
    }
}

extension TranscriptViewController {
    private func decide(_ decision: Decision, forCall callID: String) {
        sessions.respond(toCall: callID, at: fileURL) { decision.permissionDecision(for: $0) }
    }
}

extension TranscriptViewController: ComposerViewDelegate {
    func composerView(_ composerView: ComposerView, didSubmit text: String) {
        let (sessions, url) = (sessions, fileURL)
        Task { [weak composerView] in
            do {
                try await sessions.send(text, to: url)
            } catch {
                appLog(.error, "TranscriptViewController", "send failed: \(error)")
                composerView?.showFailure(
                    String(localized: "Couldn’t send the message: \(error.localizedDescription)"), of: text)
            }
        }
    }

    func composerViewDidRequestStop(_ composerView: ComposerView) {
        sessions.interrupt(at: fileURL)
    }
}
