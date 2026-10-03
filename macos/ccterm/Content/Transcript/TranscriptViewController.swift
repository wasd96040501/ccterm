import AgentSDK
import AppKit
import TranscriptKit

/// A session's transcript in a `TranscriptView`: a session tab's, or a
/// subagent's conversation on its own.
///
/// Shows the states it is handed (`show(_:)`) — by its container, which
/// follows the session once for the whole tab, or by `follow(_:)` for a
/// conversation with no container. Nothing is shown before the view has
/// its size; each state becomes a `TranscriptPage` off the main actor. The
/// first page shows its last screen of rows at once and prepends the history
/// behind it a chunk at a time — scroll anchoring keeps the reader's place
/// while it arrives; every later page (a live session's) is applied as the
/// changes from the rows shown (`PageRow.changes`). Only the newest state
/// waits while a page is being shown, so a live page never lands on a
/// half-shown first one.
///
/// Owns what the reader does to the page: which runs are open
/// (`RunDisclosure`), which item's document is showing (the selection), and
/// bringing an item back into view. What opening a document does is the
/// delegate's; what sending, stopping and answering do is the store's.
///
/// Honours its own safe area: whatever a container lays over its bottom edge
/// (`additionalSafeAreaInsets`), the last row scrolls clear of it. The
/// transcript anchors that change like a row mutation — at the tail it stays
/// at the tail, anywhere else the rows in view hold still.
@MainActor
final class TranscriptViewController: NSViewController {
    /// The file this tab shows — what the tab is, for finding it again.
    let fileURL: URL

    /// The window: opening a document beside, revealing.
    weak var tabDelegate: TranscriptTabDelegate?
    /// The tab around it, when there is one.
    weak var delegate: TranscriptViewControllerDelegate?

    private let sessions: SessionStore
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
    /// The picture whose token the pointer is over: its thumbnail is outlined.
    private var hoveredImage: (entry: String, number: Int)?
    /// The newest state handed over and not shown yet, or that the session
    /// couldn't be read.
    private var pending: Pending?
    private enum Pending {
        case state(SessionState)
        case unreadable
    }
    /// Shows pending states, one page at a time; `nil` when idle.
    private var showTask: Task<Void, Never>?
    /// Follows a stream for a conversation with no container.
    private var followTask: Task<Void, Never>?
    private var hasAppeared = false
    private var hasShownFirst = false
    /// Whether the transcript is at its end (`didChangeTailFollowing`).
    private var isFollowingTail = true
    /// What the delegate was last told of the waiting request's visibility.
    private var reportedWaitingRequestVisibility: Bool?

    init(fileURL: URL, title: String, sessions: SessionStore) {
        self.fileURL = fileURL
        self.sessions = sessions
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = SafeAreaView()
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
        transcript.contentInsets = NSEdgeInsets(top: 12, left: 0, bottom: Self.bottomGap, right: 0)
        transcript.dataSource = self
        transcript.delegate = self
    }

    /// Mount, lay out, then load (`TranscriptKit` §5): here rather than in
    /// `viewWillAppear()`, where a tab's view has no size yet.
    override func viewDidAppear() {
        super.viewDidAppear()
        guard !hasAppeared else { return }
        hasAppeared = true
        view.layoutSubtreeIfNeeded()
        showPending()
    }

    /// Shows `state` — at once if nothing is being shown, else once the page
    /// in progress is; a newer state replaces one still waiting.
    func show(_ state: SessionState) {
        pending = .state(state)
        showPending()
    }

    /// Says the transcript couldn't be read.
    func showUnreadable() {
        pending = .unreadable
        showPending()
    }

    /// Follows `states` itself — a conversation with no container (a
    /// subagent's, inside its document) — until removed.
    func follow(_ states: AsyncThrowingStream<SessionState, Error>) {
        followTask = Task { [weak self] in
            do {
                for try await state in states { self?.show(state) }
            } catch {
                self?.showUnreadable()
            }
        }
    }

    /// Stops a load in flight. The editor area calls it before the tab leaves
    /// the tree.
    func prepareForRemoval() {
        followTask?.cancel()
        followTask = nil
        showTask?.cancel()
        showTask = nil
    }

    /// Brings the request waiting for the reader into view (*Waiting for you ↑*):
    /// its approval card, question or plan decision, centred.
    func revealWaitingRequest() {
        guard let row = waitingRow else { return }
        transcript.scrollToRow(at: row, scrollPosition: .center)
        updateWaitingRequestVisibility()
    }

    /// The row of the request waiting for the reader — the newest, since a
    /// request is always the end of the conversation — if any.
    private var waitingRow: Int? {
        rows.lastIndex { row in
            switch row.kind {
            case .approval, .planDecision: true
            case .question(let question): question.isWaiting
            default: false
            }
        }
    }

    /// Tells the delegate when the waiting request comes into view or leaves it:
    /// at the tail, or any part of its row inside the safe area. With no request waiting it is trivially in view. A row not laid
    /// out yet says nothing.
    ///
    /// Computed when the page changes, the inset or size changes, the transcript
    /// reaches or leaves its end, whenever it scrolls (`transcriptViewDidScroll`,
    /// once per runloop pass) and on `revealWaitingRequest()`.
    private func updateWaitingRequestVisibility() {
        let visible: Bool
        if let row = waitingRow {
            let rect = transcript.rect(ofRow: row)
            if isFollowingTail {
                visible = true
            } else if rect == .zero {
                return
            } else {
                let shown = NSRect(
                    x: 0, y: 0, width: transcript.bounds.width,
                    height: max(transcript.bounds.height - view.safeAreaInsets.bottom, 0))
                visible = rect.intersects(shown)
            }
        } else {
            visible = true
        }
        guard visible != reportedWaitingRequestVisibility else { return }
        reportedWaitingRequestVisibility = visible
        delegate?.transcriptViewController(self, didChangeWaitingRequestVisibility: visible)
    }

    /// The space under the last row, above the safe area's bottom edge.
    private static let bottomGap: CGFloat = 24

    override func viewDidLayout() {
        super.viewDidLayout()
        let bottom = Self.bottomGap + view.safeAreaInsets.bottom
        if transcript.contentInsets.bottom != bottom { transcript.contentInsets.bottom = bottom }
        updateWaitingRequestVisibility()
    }

    private func showPending() {
        guard hasAppeared, showTask == nil, pending != nil else { return }
        showTask = Task { [weak self] in
            while let self, !Task.isCancelled, let next = self.pending {
                self.pending = nil
                switch next {
                case .state(let state):
                    let page = await Task.detached(priority: .userInitiated) { Self.page(state) }.value
                    guard !Task.isCancelled else { return }
                    if self.hasShownFirst {
                        self.apply(page)
                    } else {
                        self.hasShownFirst = true
                        await self.show(page)
                    }
                case .unreadable:
                    await self.show(Self.note(String(localized: "This transcript couldn’t be read.")))
                }
            }
            self?.showTask = nil
        }
    }

    // MARK: - Loading

    /// The page of `state`; a transcript at rest with nothing on it says so —
    /// a live one is just empty until the first prompt.
    private nonisolated static func page(_ state: SessionState) -> TranscriptPage {
        let page = TranscriptPage(
            state.transcript, partial: state.partial, requests: state.requests, prompts: state.prompts,
            restarts: state.restarts)
        if page.entries.isEmpty, state.phase == .atRest {
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
        let batch = { [transcript] in
            transcript.performBatchUpdates {
                if !changes.removed.isEmpty { transcript.removeRows(at: changes.removed) }
                for move in changes.moved { transcript.moveRow(at: move.from, to: move.to) }
                if !changes.inserted.isEmpty { transcript.insertRows(at: changes.inserted) }
                if !changes.reloaded.isEmpty { transcript.reloadRows(at: changes.reloaded) }
                if !changes.regapped.isEmpty { transcript.noteHeightOfRows(withIndexesChanged: changes.regapped) }
            }
        }
        if changes.moved.isEmpty {
            batch()
        } else {
            // A queued prompt the CLI folded into the turn moves in one 0.25-s
            // slide; outside a group a move takes the table's 0.4 s.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                batch()
            }
        }
        updateWaitingRequestVisibility()
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
        updateWaitingRequestVisibility()
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
        guard let delegate = tabDelegate else { return }
        let sessions = sessions
        delegate.transcriptTab(
            self, didRequestOpen: .document(document.reference), pinned: pinned,
            makeItem: { TranscriptTab.makeDocumentItem(document, sessions: sessions, delegate: delegate) })
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
        let highlighted = hoveredImage.flatMap { $0.entry == pageRow.id.entry ? $0.number : nil }
        return pageRow.makeView(
            in: transcriptView, isSelected: opens != nil && opens == selection,
            flashes: opens != nil && opens == flashing, highlightedImage: highlighted, delegate: self)
    }

    func transcriptView(_ transcriptView: TranscriptView, didActivate url: URL, inRow row: Int) {
        // A picture's token opens the picture beside, as its thumbnail does.
        if let number = Bubble.imageNumber(of: url), rows.indices.contains(row) {
            open(PromptImage.id(entryID: rows[row].id.entry, number: number), pinned: false)
            return
        }
        NSWorkspace.shared.open(url)
    }

    func transcriptView(_ transcriptView: TranscriptView, didChangeTailFollowing isFollowingTail: Bool) {
        self.isFollowingTail = isFollowingTail
        updateWaitingRequestVisibility()
    }

    func transcriptViewDidScroll(_ transcriptView: TranscriptView) {
        updateWaitingRequestVisibility()
    }

    /// Over a picture's token the thumbnail above the bubble is outlined.
    func transcriptView(_ transcriptView: TranscriptView, didHover url: URL?, at point: NSPoint, inRow row: Int) {
        let hovered: (entry: String, number: Int)? =
            if let url, let number = Bubble.imageNumber(of: url), rows.indices.contains(row) {
                (rows[row].id.entry, number)
            } else {
                nil
            }
        guard hovered?.entry != hoveredImage?.entry || hovered?.number != hoveredImage?.number else { return }
        let entries = Set([hoveredImage?.entry, hovered?.entry].compactMap { $0 })
        hoveredImage = hovered
        let thumbnails = IndexSet(
            rows.indices.filter { entries.contains(rows[$0].id.entry) && rows[$0].id.part == .attachments })
        if !thumbnails.isEmpty { self.transcript.reloadRows(at: thumbnails) }
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

    func pageRowView(_ rowView: NSView, didRequestWithdrawOfPrompt uuid: String) {
        sessions.withdraw(prompt: uuid, at: fileURL)
    }

    /// Sends the words again as a new prompt; the one that wasn't sent goes.
    func pageRowView(_ rowView: NSView, didRequestResendOfPrompt uuid: String) {
        guard let index = page.entryIndex(containing: uuid), case .prompt(let prompt) = page.entries[index] else {
            return
        }
        sessions.dismiss(prompt: uuid, at: fileURL)
        sessions.send(prompt.text, to: fileURL)
    }
}

extension TranscriptViewController {
    private func decide(_ decision: Decision, forCall callID: String) {
        sessions.respond(toCall: callID, at: fileURL) { decision.permissionDecision(for: $0) }
        // *Chat About This* answers nothing: the conversation is the answer.
        if case .chatAbout = decision { delegate?.transcriptViewControllerDidChooseToChat(self) }
    }
}

/// The transcript's root: lays out again when a container changes its safe
/// area, which AppKit doesn't do on its own.
private final class SafeAreaView: NSView {
    override var additionalSafeAreaInsets: NSEdgeInsets {
        didSet { needsLayout = true }
    }
}
