import AppKit

/// Re-measures the rows a width change left stale, off the main actor, nearest
/// the reader first, and publishes the corrections a batch at a time.
///
/// The transcript's half of a width change is synchronous and covers the rows on
/// screen (`TranscriptView.contentWidthDidChange()`); this is the rest — every
/// other row that already had a measurement — and it owns the one `Task` that
/// does it, cancelling a run a newer width has superseded. It publishes through
/// its owner's `noteHeightOfRows(withIndexesChanged:)`, which holds the viewport
/// still; what it files goes straight into the shared `RowCache`.
@MainActor
final class RemeasureScheduler {

    /// The re-measure in flight, or `nil`.
    ///
    /// Held for two reasons, and neither is correctness. A second width change
    /// cancels the first, so the loser stops burning cores for an answer that
    /// would be rejected anyway — measured against the alternative, letting it run
    /// costs the work and nothing else, because `publish(_:at:)` drops a batch
    /// whose width has been superseded and `RowCache` would reject the entries
    /// even if it did not. And it is what a test waits on: the corrections land on
    /// later turns, and there is no honest way to know they all have except to wait
    /// for the thing that publishes them.
    private(set) var task: Task<Void, Never>?

    private weak var owner: RemeasureSchedulerOwner?
    private let rowCache: RowCache
    private let tableView: NSTableView

    init(owner: RemeasureSchedulerOwner, rowCache: RowCache, tableView: NSTableView) {
        self.owner = owner
        self.rowCache = rowCache
        self.tableView = tableView
    }

    private var numberOfRows: Int { tableView.numberOfRows }

    /// Re-measures everything a width change invalidated, off the main actor,
    /// nearest the reader first, publishing each batch as it fills rather than the
    /// whole job at the end.
    ///
    /// **Why this is not `prepareRows` pointed at a resize.** That one is the
    /// host's to call, so the `await` lands at the host's own call site. A resize
    /// has no host call site — it is the transcript's own invalidation, arriving
    /// through `viewDidEndLiveResize` — so the transcript has to own a `Task`, and
    /// that `Task` spans main-actor turns during which the host may do anything at
    /// all. What makes that safe is that the answers are filed by identity and
    /// checked against the content they were made from: see
    /// `RowCache.merge(remeasured:at:)`, where every way it can go stale is
    /// enumerated, and every one of them costs the work rather than the render.
    ///
    /// **Nothing is invalidated until answers are in.** Calling `noteHeightOfRows`
    /// first would make the table re-ask immediately and measure the whole working
    /// set on the main thread, which is the freeze this exists to remove. So the
    /// rows off screen keep heights from the old width until a batch covering them
    /// lands, and the visible ones are already correct — `TranscriptView.contentWidthDidChange()`
    /// re-measures those synchronously, every frame of the drag and again on
    /// mouse-up.
    ///
    /// **What that window costs, precisely.** A row scrolled into while this runs
    /// gets its glyphs at the new width, because `viewForRow` misses the cache and
    /// re-measures on demand — but its *rectangle* is the table's own cached
    /// number from the old width, and the table has no reason to re-ask, since its
    /// `heightOfRow` takes no width. New glyphs in an old rect, until a batch
    /// covering that row lands. It is confined to rows the table has already
    /// measured: one it has not is asked about on the spot and comes out right.
    /// Whether that window is short enough to be beneath noticing is not something
    /// an assertion can answer — `make demo-kit` on ten thousand rows is where it
    /// gets looked at.
    ///
    /// **The window is what the order and the batching are both about.** A
    /// transcript the reader has been through for an hour has tens of thousands of
    /// measured rows, and one batch at the end would mean the whole of that before
    /// anything is corrected. Two things shorten what the reader can actually meet:
    /// the walk starts where they are looking
    /// (`staleRowsOutwardFromViewport(at:)`), and each batch is published as it
    /// fills (`publishInterval`) rather than at the end. Together
    /// those make the *relevant* window the time to correct the next screenful,
    /// which does not grow with the transcript at all — the total still does, and
    /// is spent on rows nobody is looking at.
    func beginRemeasuringOffscreenRows(at width: CGFloat) {
        task?.cancel()

        let stale = staleRowsOutwardFromViewport(at: width)
        guard !stale.isEmpty else {
            // Nothing was ever measured, so there is nothing to prepare from and
            // nothing to wait for. The table's own re-ask does the work, exactly
            // as it did before any of this existed. Goes to the table directly
            // rather than through `noteHeightOfEveryRow(at:)`: this path can run
            // inside the scroll view's own tile, where anchoring is not available.
            task = nil
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(0..<numberOfRows))
            return
        }

        // Built out here rather than inside the `Task` so that it can hold the
        // scheduler weakly: written in there, `self` is already the outer
        // capture's optional and weakening it again reads as a puzzle.
        let publish: @MainActor @Sendable (Batch) -> UInt64 = { [weak self] batch in
            self?.publish(batch, at: width) ?? 0
        }
        task = Task { [weak self] in
            await Self.remeasure(stale, at: width, publish: publish)
            // A cancelled run has already been replaced; clearing here would clear
            // its successor.
            guard !Task.isCancelled, let self else { return }
            task = nil
            noteHeightOfEveryRow(at: width)
        }
    }

    /// One batch of answers: what each row now measures to, and which row that was
    /// when the walk passed it.
    ///
    /// The row number is not what the answer is filed under — that is the identity,
    /// and `RowCache` still holds no positions. It is only what the table has to be
    /// told changed, and it is allowed to be wrong: see `publish(_:at:)`.
    private typealias Batch = [(row: Int, id: TranscriptRow.ID, entry: RowCache.Entry)]

    /// Everything a width change invalidated, in the order it should be corrected:
    /// the rows on screen, then one below, one above, one below, out to both ends.
    ///
    /// **Why the order is the point.** Row 0 of a ten-thousand-row transcript is
    /// nine thousand rows of scrolling away from mattering; the row just past the
    /// bottom edge is one flick away. Working outward from the reader is what makes
    /// the window they can actually meet the time to correct the next screenful,
    /// which does not grow with the transcript — where the cache's own dictionary
    /// order would put that row anywhere at all.
    ///
    /// **Why the transcript does this and the cache does not.** `RowCache` is keyed
    /// on identity and holds no positions — that is the whole of what the identity
    /// bought (see its `What the identity deleted`). Which row an entry belongs to
    /// is therefore a question only the data source can answer, and only on the main
    /// actor, so this is where it gets asked.
    ///
    /// **It costs a walk, and the walk stops early.** One `rowAt` per row passed,
    /// as `TranscriptView.sweepCache()` also does, until every stale entry has been claimed. What
    /// bounds it is not the transcript's length but how far the *farthest measured
    /// row* is from the viewport — a reader who has stayed near the tail is a few
    /// hundred rows, one who has read the whole thing is all of it. Measured on ten
    /// thousand rows with every one of them measured, which is that worst case:
    /// **12 ms**, against the 1.9 s of measuring whose order it is deciding.
    ///
    /// Entries left over belong to rows the data source no longer has — an id a
    /// `removeRows` orphaned and no sweep has reached yet. They are dropped rather
    /// than measured: nothing will ever ask for them.
    private func staleRowsOutwardFromViewport(at width: CGFloat) -> Batch {
        var pending = rowCache.entries(measuredAtWidthOtherThan: width)
        guard !pending.isEmpty, let owner else { return [] }

        // Clamped rather than trusted: the table answers about the geometry it last
        // laid out, and answers `NSNotFound` for a viewport with no rows in it.
        let onScreen = tableView.rows(in: tableView.visibleRect)
        let visible =
            onScreen.length > 0
            ? (onScreen.location..<(onScreen.location + onScreen.length))
                .clamped(to: 0..<numberOfRows)
            : 0..<0

        var ordered: Batch = []
        ordered.reserveCapacity(pending.count)
        var inside = visible.makeIterator()
        var below = visible.upperBound
        var above = visible.lowerBound - 1
        // Flipped by each step that takes the side it names, so a side that has run
        // out is skipped without flipping it and the survivor runs on alone. A tie
        // goes downwards, because a transcript is read downwards.
        var takesBelow = true
        while !pending.isEmpty {
            let row: Int
            if let onScreen = inside.next() {
                row = onScreen
            } else if below < numberOfRows, takesBelow || above < 0 {
                row = below
                below += 1
                takesBelow = false
            } else if above >= 0 {
                row = above
                above -= 1
                takesBelow = true
            } else {
                break
            }
            // No row is "no data source", which is nothing to order.
            guard let id = owner.row(at: row)?.id else { return [] }
            if let entry = pending.removeValue(forKey: id) { ordered.append((row, id, entry)) }
        }
        return ordered
    }

    /// The shortest a batch may collect for, whatever the rule below works out.
    ///
    /// One frame at 60 Hz. Two batches inside one frame is one batch nobody saw,
    /// and it is the *only* floor that matters — a small transcript's publish costs
    /// so little that the rule below would otherwise publish per result.
    ///
    /// Nanoseconds off `DispatchTime` rather than a `Duration` off
    /// `ContinuousClock`, which is macOS 13 and this package is 12.
    private nonisolated static let publishFloor: UInt64 = 16_000_000

    /// How many times as long a batch collects for as the last one took to apply,
    /// which is what actually paces this.
    ///
    /// **Neither a fixed count of rows nor a fixed slice of time, and both were
    /// tried.** A row count is the wrong currency outright: a row here is a
    /// one-line paragraph and a row there is a four-hundred-line code fence, so any
    /// count is either a batch too small to be worth the hop or one long enough to
    /// be the whole job again. A fixed slice is better and still wrong, because
    /// what a batch *costs* is not fixed — applying one is `noteHeightOfRows` plus
    /// a layout, which is work proportional to the transcript, on a main thread
    /// whose speed depends on what else the machine is doing. Measured on the
    /// demo's ten thousand rows, one publish cost 5 ms on a quiet machine and 15 ms
    /// on a loaded one; at a fixed 8 ms slice that was 609 publishes and **1.9 s**
    /// of main thread, which is a tenth of the freeze this whole design removed,
    /// handed back.
    ///
    /// Pacing off the cost fixes both ends at once: the share of the main thread is
    /// pinned wherever this number puts it, on any transcript and any machine, and
    /// nothing has to know how long a row takes or how many there are. Twenty gives
    /// the correction about 5% of the window — measured, **77 publishes and 0.41 s**
    /// over the same ten thousand rows, in hops of 0.5 to 13 ms.
    private nonisolated static let publishInterval: UInt64 = 20

    /// How many rows are being measured at once.
    ///
    /// **Not a throughput knob — the collecting task is what this protects.** Every
    /// row queued at once is what `prepareRows` does, on the reasoning that the pool
    /// runs only as many as there are cores and the rest cost a task object each.
    /// That reasoning misses this loop: the task doing the collecting is itself on
    /// the pool, so ten thousand runnable children make it one starved job among ten
    /// thousand. Measured, on the demo's ten thousand: the collector took **78
    /// results in 10.8 s**, then the remaining 9 900 in the 90 ms after the last
    /// child finished — which is to say the batching did nothing at all, and every
    /// correction arrived at the end exactly as if none of this existed.
    ///
    /// `prepareRows` keeps the unbounded version because it has no such loop: it
    /// collects into a dictionary, hops nowhere, and nobody is waiting on it
    /// part-way.
    private nonisolated static let inFlightLimit = ProcessInfo.processInfo.activeProcessorCount

    /// The stale entries, re-measured concurrently, handed over a batch at a time.
    ///
    /// `nonisolated` because a `static` member of a
    /// `@MainActor` type is isolated by default and this one must not be. What
    /// crosses is `RowCache.Entry`, which is `Sendable` and carries its own
    /// recipe — so this is line-breaking and nothing else. No parse, no shaping,
    /// no data source.
    ///
    /// **Order survives the fan-out, because only `inFlightLimit` rows are in the
    /// air.** Nearest-first in, nearest-first out to within a core count — near
    /// enough that a batch is a contiguous band around the viewport. Nothing depends
    /// on more than that: a row in the wrong batch is corrected one batch later.
    ///
    /// **`publish` is `@MainActor`, and that is the whole of the hand-over.** The
    /// hop is the `await` on it; between hops this runs on the pool. It answers what
    /// applying the batch cost, which is what sets how long the next one collects
    /// for — the cost of *applying*, not of getting on: waiting for a main thread
    /// that is busy with something else is already its own back-pressure, and
    /// charging for it too would back off twice.
    private nonisolated static func remeasure(
        _ stale: Batch, at width: CGFloat,
        publish: @escaping @MainActor @Sendable (Batch) -> UInt64
    ) async {
        await withTaskGroup(of: (row: Int, id: TranscriptRow.ID, entry: RowCache.Entry)?.self) {
            group in
            var next = 0
            func addNext() {
                guard next < stale.count else { return }
                let item = stale[next]
                next += 1
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    return (item.row, item.id, item.entry.remeasured(at: width))
                }
            }
            for _ in 0..<Swift.min(stale.count, inFlightLimit) { addNext() }

            var batch: Batch = []
            var interval = publishFloor
            var opened = DispatchTime.now().uptimeNanoseconds
            for await result in group {
                addNext()
                guard let result else { continue }
                batch.append(result)
                guard DispatchTime.now().uptimeNanoseconds - opened >= interval else { continue }
                interval = Swift.max(publishFloor, await publish(batch) * publishInterval)
                batch.removeAll(keepingCapacity: true)
                // Restarted after the hand-over rather than before it, so the
                // budget is a floor on *measuring* between publishes. Timing it
                // from before would let a slow publish schedule the next one
                // immediately, which is the opposite of what a budget is for.
                opened = DispatchTime.now().uptimeNanoseconds
            }
            if !batch.isEmpty { _ = await publish(batch) }
        }
    }

    /// Files one batch and tells the table, in that order and in one turn.
    ///
    /// **Only the rows this batch carried, and that is the whole difference between
    /// this working and this being the freeze again.** `noteHeightOfRows` is not a
    /// note — the table re-asks, inside the call, for the rows it is told about that
    /// it has heights for. When the batches were published one at a time and each
    /// invalidated the whole transcript, the first one therefore re-asked about ten
    /// thousand rows of which it had corrected seventy: the other 9 930 missed the
    /// cache and were re-measured on the main thread, one document at a time.
    /// Measured, on the demo's ten thousand: **2 466 ms in a single call**, which is
    /// worse than the whole-job freeze this design replaced. Invalidating exactly
    /// what was corrected is answered entirely from the cache — same transcript,
    /// **8 to 12 ms**.
    ///
    /// **The row numbers are allowed to be wrong.** They were read when the walk
    /// passed the row and the host may have inserted or removed since, so a note can
    /// land on the wrong row: an uncorrected row gets invalidated (it is re-measured
    /// on demand, correctly, one row's cost) and a corrected one does not (it keeps
    /// the old width's rectangle). The second is the one that would persist, which
    /// is what `noteHeightOfEveryRow(at:)` at the end of the run is for — by then
    /// everything is in the cache, so invalidating the lot is answered from it.
    ///
    /// **Anchored, unlike the synchronous half of a width change.** §2 puts a
    /// resize outside both anchoring rules, and the reason it gives is that the
    /// re-measure runs inside the scroll view's own tile, where writing a scroll
    /// offset would be writing into the layout producing it. That reason does not
    /// reach here: this runs on a later turn, from a task continuation, with the
    /// tile long finished. Anchoring matters more the smaller the batches get —
    /// each one changes the height of rows above the viewport, and unanchored that
    /// is the content stepping under the reader once per batch instead of once per
    /// resize.
    ///
    /// The transcript's `noteHeightOfRows(withIndexesChanged:)` goes through its
    /// `mutate`, which also suppresses the implicit animation the row geometry would
    /// otherwise take (see `TranscriptView.suppressImplicitAnimation()`) — a hundred rows sliding
    /// to new positions over a quarter second, repeatedly, while the reader is
    /// trying to read.
    ///
    /// **What is left here is thrift.** Publishing a superseded batch, or one whose
    /// rows have moved on, is self-correcting: the entries carry the width they were
    /// measured at, so the very next read rejects them and measures again, inside
    /// the same pass — no frame is drawn wrong. The merge is likewise an
    /// optimisation and not a correctness step, since the invalidation makes the
    /// table re-ask and a row with no usable entry is simply measured then. Which is
    /// the whole point, and also why no assertion can see it: with the merge removed
    /// the transcript is still right, it is just measuring on the main thread again.
    /// The evidence for it is a measurement, in §6.
    /// - Returns: what this cost, in nanoseconds — the number that paces the next
    ///   batch. See `publishInterval`.
    @discardableResult
    private func publish(_ batch: Batch, at width: CGFloat) -> UInt64 {
        let started = DispatchTime.now().uptimeNanoseconds
        guard let owner, width == owner.contentWidth, numberOfRows > 0 else { return 0 }

        var rows = IndexSet()
        var entries: [(id: TranscriptRow.ID, entry: RowCache.Entry)] = []
        entries.reserveCapacity(batch.count)
        for item in batch {
            guard item.row < numberOfRows else { continue }
            rows.insert(item.row)
            entries.append((item.id, item.entry))
        }
        rowCache.merge(remeasured: entries, at: width)
        owner.noteHeightOfRows(withIndexesChanged: rows)
        return DispatchTime.now().uptimeNanoseconds - started
    }

    /// Invalidates every row's height, once the run that corrected them has
    /// finished.
    ///
    /// Cheap exactly because it is last: every answer is in the cache by now, so
    /// the re-ask this provokes is a lookup per row rather than a measurement.
    /// **8 ms** on ten thousand rows, against the 2 466 ms the same call costs
    /// against a cache that is still mostly stale (see `publish(_:at:)`).
    ///
    /// It exists to catch the rows whose numbers moved under the batches.
    ///
    /// Anchored, for the reason `publish(_:at:)` gives — which is also why the
    /// "nothing was stale" path in `beginRemeasuringOffscreenRows(at:)` does not
    /// come through here despite wanting the same call: that one can run inside the
    /// scroll view's own tile, where anchoring is not available.
    private func noteHeightOfEveryRow(at width: CGFloat) {
        guard let owner, width == owner.contentWidth, numberOfRows > 0 else { return }
        owner.noteHeightOfRows(withIndexesChanged: IndexSet(0..<numberOfRows))
    }
}
