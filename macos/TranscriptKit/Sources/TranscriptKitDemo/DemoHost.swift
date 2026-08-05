import AppKit
import TranscriptKit
import TranscriptMedia

/// Data source and delegate for the demo: the script in `DemoMessage.swift`,
/// plus the mutations the control panel drives.
///
/// Every mutation is the same two lines a real host writes — change the model,
/// then announce the change — and each announcement is deliberately the
/// index-based one rather than `reloadData()`, since that is what scroll
/// anchoring applies to.
@MainActor
final class DemoHost: NSObject, TranscriptViewDataSource, TranscriptViewDelegate {

    private var messages: [DemoMessage] = DemoMessage.script
    private var mutationCount = 0

    weak var transcript: TranscriptView?
    var onRowCountChange: ((Int) -> Void)?

    /// Whether a row is currently streaming, so the panel's button can say
    /// **Stop** — including when the stream ended by running out of text rather
    /// than by being stopped.
    var onStreamingChange: ((Bool) -> Void)?

    // MARK: - Mutations

    /// Above the viewport, wherever the viewport is: the case where holding the
    /// content still is the whole point.
    func prepend(_ count: Int) {
        let inserted = (0..<count).map { index in
            DemoMessage.assistant(label("▲ prepended", index))
        }
        messages.insert(contentsOf: inserted, at: 0)
        transcript?.insertRows(at: IndexSet(0..<count))
        reportRowCount()
    }

    /// Below everything: the case where the answer depends on where the reader is
    /// — at the end it follows, anywhere else it doesn't move.
    func append() {
        messages.append(.user(label("▼ appended", 0)))
        transcript?.insertRows(at: IndexSet(integer: messages.count - 1))
        reportRowCount()
    }

    func removeTop(_ count: Int) {
        let removed = min(count, messages.count)
        guard removed > 0 else { return }
        messages.removeFirst(removed)
        transcript?.removeRows(at: IndexSet(0..<removed))
        reportRowCount()
    }

    /// A row above the viewport changing height without changing identity — the
    /// mutation that has no index set to shift, only geometry to compensate for.
    func growFirstRow() {
        guard !messages.isEmpty else { return }
        messages[0] = messages[0].appending(
            String(repeating: "This row keeps growing. ", count: 6))
        transcript?.reloadRows(at: IndexSet(integer: 0))
    }

    /// The same height change announced without re-rendering the row: the other
    /// public path to it, and the one a hosted view uses when it grows itself.
    func remeasureFirstRow() {
        guard !messages.isEmpty else { return }
        messages[0] = messages[0].appending(
            String(repeating: "Re-measured, not re-rendered. ", count: 4))
        transcript?.noteHeightOfRows(withIndexesChanged: IndexSet(integer: 0))
    }

    /// Two mutations, one anchor: five rows in at the top and three out from just
    /// below them, so the renumbering has to compose across the group.
    func prependAndRemoveInOneBatch() {
        // The removal is expressed in post-insert indices, so it needs three
        // rows to exist below the five going in.
        guard messages.count >= 8 else { return }
        transcript?.beginUpdates()
        prepend(5)
        messages.removeSubrange(10..<13)
        transcript?.removeRows(at: IndexSet(10..<13))
        transcript?.endUpdates()
        reportRowCount()
    }

    // MARK: - Cold load

    /// Loads `total` rows the way a host with a long history is meant to:
    /// **one screen synchronously, then the rest prepared off the main actor and
    /// prepended in chunks.**
    ///
    /// This is `TranscriptView.prepareRows(_:)`'s doc comment, written out as
    /// something you can press. What the demo adds is the half no assertion has
    /// an opinion about: whether the window still *feels* alive while it runs.
    /// Press this and then drag the window, spin the scroll wheel, select some
    /// text in the row under the pointer — all of it keeps working, and the
    /// panel's timing line says why. Press **Cold load (sync)** for the same
    /// transcript loaded the obvious way and try the same three things.
    ///
    /// Three properties are on screen at once here, and only the first is
    /// assertable:
    ///
    /// - Each chunk lands **above** the viewport while the reader sits at the
    ///   tail, and scroll anchoring holds the content still through every one of
    ///   them. Watch a line of text, not the scroller.
    /// - The scroller's knob shrinks in steps as history arrives, because the
    ///   document really is getting longer — this is not an estimate being
    ///   corrected, so it never grows back.
    /// - The main thread's share is bounded by the *seed*, not by the
    ///   typesetting. That is the number the panel prints.
    ///
    /// Measured on an M-series laptop, ten thousand rows, five hundred to a
    /// chunk — the numbers the two buttons print, so they can be checked rather
    /// than believed:
    ///
    /// | | main thread, total | worst single chunk |
    /// |---|---|---|
    /// | **Sync** | 12.47 s | 665 ms |
    /// | **Prepared** | 0.12 s | 11 ms |
    ///
    /// The worst chunk is the interesting column. 665 ms is forty dropped frames
    /// happening twenty times; 11 ms fits inside a frame, which is why one of
    /// these can be scrolled through while it loads and the other cannot. Note
    /// also that the prepared figure *grows* across the load — 1 ms for the first
    /// chunk, 11 ms for the last — because what is left in the insert is the
    /// table's own bookkeeping, which is proportional to how many rows it already
    /// has. That is the next thing to look at if this ever needs to be cheaper,
    /// and it is not something this package can move off the main thread.
    func coldLoad(rows total: Int, prepared: Bool) {
        cancelColdLoad()
        stopStreaming()
        let documents = StressCorpus.documents(count: max(total, 0))
        guard !documents.isEmpty, let transcript else { return }

        // Phase 1 — one screen, synchronously. A dozen rows measure in well under
        // a millisecond, and routing them through a background hop would only
        // push the first paint a frame later for no gain. `reloadData()` rather
        // than an insert because there is nothing yet to insert into.
        let firstScreen = min(Self.firstScreenRows, documents.count)
        var pending = documents
        messages = pending.suffix(firstScreen).map { .assistant($0) }
        pending.removeLast(firstScreen)
        transcript.reloadData()
        transcript.scrollToRow(at: messages.count - 1, scrollPosition: .bottom)
        reportRowCount()

        // Phase 2 — the history, oldest-ward, a chunk at a time.
        coldLoadTask = Task { [weak self] in
            var report = ColdLoadReport(total: documents.count, prepared: prepared)
            while !pending.isEmpty {
                guard let self, let transcript = self.transcript, !Task.isCancelled else { return }
                let chunk = Array(pending.suffix(Self.chunkRows))
                pending.removeLast(chunk.count)

                // The batch measured off the main actor. The `String`s handed
                // over are the same instances that go into `messages` below —
                // not copies — which is what keeps the seed's per-row check a
                // pointer comparison. See `prepareRows(_:)`.
                var seeded: PreparedRows?
                if prepared {
                    let started = DispatchTime.now()
                    seeded = await transcript.prepareRows(chunk.map { .markdown($0) })
                    report.offMain += Self.seconds(since: started)
                    if Task.isCancelled { return }
                }

                // ↓↓ No suspension point between mutating the model and
                //    announcing it. The one rule. ↓↓
                let started = DispatchTime.now()
                self.messages.insert(contentsOf: chunk.map { .assistant($0) }, at: 0)
                let indexes = IndexSet(0..<chunk.count)
                if let seeded {
                    transcript.insertRows(at: indexes, prepared: seeded)
                } else {
                    transcript.insertRows(at: indexes)
                }
                report.record(mainThread: Self.seconds(since: started))

                self.reportRowCount()
                self.onColdLoadProgress?(report.line(loaded: self.messages.count))

                // One chunk per hop even in the prepared case, and the reason is
                // not the frame budget — an insert that only seeds does not blow
                // one. It is that a `Task` that never suspends between chunks
                // starves the main queue of everything else: without this, the
                // synchronous run would show no intermediate state at all, and
                // the two buttons would be much harder to tell apart for the
                // wrong reason.
                await Task.yield()
            }
            self?.coldLoadTask = nil
        }
    }

    func cancelColdLoad() {
        coldLoadTask?.cancel()
        coldLoadTask = nil
    }

    var isColdLoading: Bool { coldLoadTask != nil }

    /// Reported to the panel after every chunk.
    var onColdLoadProgress: ((String) -> Void)?

    private var coldLoadTask: Task<Void, Never>?

    /// Enough to fill the window at the demo's default size with room to spare.
    /// The point is that phase 1 is *small*, not that it is exact — a host would
    /// take this from whatever its store hands back first.
    private static let firstScreenRows = 20

    /// See `prepareRows(_:)`: the unit of work a resize or a cancellation throws
    /// away, not a frame-budget number.
    private static let chunkRows = 500

    private static func seconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    }

    /// What the panel prints while a cold load runs.
    ///
    /// The main-thread total and the worst single chunk are the two numbers the
    /// whole exercise is about, and they are kept apart because they fail
    /// differently: a large total is a slow load, where a large *worst* is a
    /// visible hitch no matter how good the total is.
    private struct ColdLoadReport {
        let total: Int
        let prepared: Bool
        var offMain: Double = 0
        var onMain: Double = 0
        var worstChunk: Double = 0

        mutating func record(mainThread seconds: Double) {
            onMain += seconds
            worstChunk = max(worstChunk, seconds)
        }

        func line(loaded: Int) -> String {
            let mode = prepared ? "prepared" : "sync"
            let off = prepared ? String(format: "  off-main %.2fs", offMain) : ""
            return String(
                format: "%@ · %d/%d rows%@  main %.2fs  worst chunk %.0f ms",
                mode, loaded, total, off, onMain, worstChunk * 1000)
        }
    }

    // MARK: - Streaming

    /// The row being streamed into, what it held when the stream started, and
    /// how much of `DemoMessage.streamed` has been revealed. `nil` when nothing
    /// is streaming.
    ///
    /// The base is captured rather than appended to in place so that "grow by two
    /// characters" is exact — a frame the timer drops changes when the text
    /// arrives, never how much of it there is.
    private var stream: (row: Int, base: String, revealed: Int)?

    private var ticker: Timer?

    /// How many characters a frame reveals. Sixty frames a second at two
    /// characters each is roughly a fast typist, and slow enough that what the
    /// panel is for — watching the blocks *above* the growing one stay put — is
    /// watchable.
    private static let charactersPerFrame = 2

    /// Starts streaming into `row`, or stops the stream already running.
    ///
    /// A row is picked rather than assumed to be the last one, because the two
    /// interesting cases are different: streaming the tail is what an app does,
    /// and streaming a row *above the viewport* is where scroll anchoring and a
    /// growing row meet — the content under the reader must not move while it
    /// runs.
    ///
    /// Assistant turns only, which the pattern match is what enforces. A user
    /// turn is what someone typed, verbatim and whole — there is no version of it
    /// that arrives a token at a time, and revealing markdown into one would
    /// render the punctuation rather than the document, since `.userMessage` is
    /// plain text on purpose. A picture row has no text to reveal at all.
    func toggleStreaming(row: Int) {
        guard stream == nil else { return stopStreaming() }
        guard row >= 0, row < messages.count,
            case .assistant(let base) = messages[row].content
        else { return }

        stream = (row, base, 0)
        // `.common`, or the reveal freezes for as long as a scroll or a drag is
        // in flight — which is precisely when someone is checking that it doesn't
        // disturb them.
        let ticker = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.revealNextFrame() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
        onStreamingChange?(true)
    }

    func stopStreaming() {
        guard stream != nil else { return }
        stream = nil
        ticker?.invalidate()
        ticker = nil
        onStreamingChange?(false)
    }

    /// One frame: grow the row's text and announce it. **The whole of what a
    /// streaming host does** — change the model, name the row. Everything about
    /// what changed inside the document is the transcript's to work out, which is
    /// the design this is here to demonstrate rather than describe.
    private func revealNextFrame() {
        guard let stream, stream.row < messages.count else { return stopStreaming() }

        let revealed = min(stream.revealed + Self.charactersPerFrame, DemoMessage.streamed.count)
        messages[stream.row] = .assistant(
            stream.base + DemoMessage.streamed.prefix(revealed))
        transcript?.reloadRows(at: IndexSet(integer: stream.row))

        self.stream = (stream.row, stream.base, revealed)
        if revealed == DemoMessage.streamed.count { stopStreaming() }
    }

    private func label(_ prefix: String, _ index: Int) -> String {
        mutationCount += 1
        return "\(prefix) #\(mutationCount).\(index) — watch whether this pushed the text you "
            + "were reading off its line."
    }

    private func reportRowCount() {
        onRowCountChange?(messages.count)
    }

    // MARK: - Data source and delegate

    func numberOfRows(in transcriptView: TranscriptView) -> Int {
        messages.count
    }

    /// Text rows are the transcript's to draw — an assistant turn as a markdown
    /// document, a user turn as a bubble. Pictures are the demo's, through the
    /// one case the vocabulary keeps for exactly that.
    func transcriptView(
        _ transcriptView: TranscriptView, contentForRow row: Int
    ) -> TranscriptRowContent {
        switch messages[row].content {
        case .assistant(let text): return .markdown(text)
        case .user(let text): return .userMessage(text)
        case .images: return .view
        }
    }

    // MARK: - The picture row

    /// Asked of every picture row in the transcript on every content-width
    /// change, so it runs the mosaic and builds nothing. `ImageGridView` computes
    /// it from the same layout it will later draw, which is what keeps the height
    /// reserved here and the height drawn there from drifting apart.
    func transcriptView(
        _ transcriptView: TranscriptView, heightOfRow row: Int, width: CGFloat
    ) -> CGFloat {
        guard case .images(let urls) = messages[row].content else { return 0 }
        return ImageGridView.height(for: urls, width: width)
    }

    /// Recycled through the transcript's pool, and re-bound completely — the
    /// pictures **and** the closure, since a recycled instance is still carrying
    /// the row it was serving a moment ago in both.
    func transcriptView(
        _ transcriptView: TranscriptView, viewForRow row: Int
    ) -> NSView {
        let grid = transcriptView.makeView(withIdentifier: .imageGrid) { ImageGridView() }
        guard case .images(let urls) = messages[row].content else { return grid }
        grid.configure(with: urls)
        grid.onActivate = { [weak grid] index, tile in
            guard let grid, index < urls.count else { return }
            MediaOverlayWindow.present(
                ImagePreviewView(url: urls[index]),
                from: grid.convert(tile, to: transcriptView),
                // Taken here rather than inside the overlay, because it has to be
                // taken while the tile is still the thing on screen.
                sourceSnapshot: grid.snapshot(ofTile: index),
                in: transcriptView)
        }
        return grid
    }

    // MARK: - The rest of a long message
    //
    // Deliberately not implemented, the way the context menu above is not. The
    // transcript reports `didActivateMoreInRow:` and its default is a no-op,
    // so what the demo shows is a host that has not decided where the rest of a
    // cut-short message goes: the run is drawn, it hovers, it takes a press, and
    // nothing opens.
    //
    // That is the state worth having on screen while the *picture* preview is
    // being read, because the two would open the same overlay and only one of
    // them is being looked at.

    // MARK: - Links

    /// Opening it is the host's too, and this is the whole of what that takes.
    ///
    /// Guarded on a scheme because a document's links are not all addresses: the
    /// demo's images point at `block-tree.png` and friends, which are relative
    /// paths to files that do not exist. Handing one of those to the workspace
    /// asks it to open something relative to nothing. A real host would resolve
    /// them against wherever the document came from.
    func transcriptView(
        _ transcriptView: TranscriptView, didActivate url: URL, inRow row: Int
    ) {
        guard url.scheme != nil else { return }
        NSWorkspace.shared.open(url)
    }

    /// Where a link goes, shown while the pointer is on it.
    ///
    /// The whole of what the transcript does here is *say which link* — this is
    /// the host deciding to draw a label for it, and the demo exists partly to
    /// show that the decision is the host's. An app might put the address in a
    /// status bar, or nothing at all.
    ///
    /// The hover is reported on change only, so this is one call per link rather
    /// than one per mouse-moved event, and `hide()` needs no state kept here.
    func transcriptView(
        _ transcriptView: TranscriptView, didHover url: URL?, at point: NSPoint, inRow row: Int
    ) {
        guard let url else { return tooltip.hide() }
        let text = url.absoluteString
        tooltip.show(text.removingPercentEncoding ?? text, at: point, in: transcriptView)
    }

    private let tooltip = LinkTooltip()

    // MARK: - The context menu
    //
    // Deliberately not implemented. `transcriptView(_:menu:forRow:)` is where a
    // host appends its own items — Quote, Retry, Copy as Markdown — and the
    // default implementation returns the transcript's menu unchanged, so what
    // the demo shows is what a host that has not thought about menus yet gets:
    // the transcript's own Copy, and nothing else.
    //
    // Nothing is lost by leaving it out. The hook's behaviour — that the host is
    // asked about the row it clicked, that its answer is what gets shown, that
    // returning `nil` suppresses the menu — is assertable, and `ContextMenuTests`
    // asserts it. The demo carries what tests cannot reach (§5), and a menu item
    // that prints to stdout is not that.
}

extension NSUserInterfaceItemIdentifier {

    /// Centralised rather than spelled at the call site: a typo in a literal is a
    /// silently un-recycled row, where a typo here does not compile.
    static let imageGrid = NSUserInterfaceItemIdentifier("DemoImageGrid")
}
