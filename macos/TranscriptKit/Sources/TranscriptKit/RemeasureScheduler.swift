import AppKit
import ExactList

/// Re-measures, off the main actor, the rows a settled width change left
/// stale, nearest the reader first, and files the answers in `RowCache`.
///
/// It tells the list nothing. The list re-measures on its own after a width
/// change — the rows on screen inside the pass that changed it, the rest on idle
/// turns (ExactList W4, W5) — by asking the transcript for heights, which the
/// transcript answers from `RowCache`. This is what makes those answers
/// lookups: the typesetting happens here, on every core, before the list asks.
/// A row the list reaches first is measured on the main actor, correctly, at one
/// row's cost; nothing here can make a row wrong.
///
/// Owns the one `Task` that does it, cancelling a run a newer width has
/// superseded.
@MainActor
final class RemeasureScheduler {

    /// The re-measure in flight, or `nil`. Held so a newer width cancels an
    /// older run, and so a test can wait for the cache to be warm.
    private(set) var task: Task<Void, Never>?

    private weak var owner: RemeasureSchedulerOwner?
    private let rowCache: RowCache
    private let list: ExactListView

    init(owner: RemeasureSchedulerOwner, rowCache: RowCache, list: ExactListView) {
        self.owner = owner
        self.rowCache = rowCache
        self.list = list
    }

    /// Re-measures everything a change to `width` left stale, off the main
    /// actor, nearest the reader first, filing each batch as it fills.
    ///
    /// Safe across the turns it spans because the answers are filed by identity
    /// and checked against the content they were made from: see
    /// `RowCache.merge(remeasured:at:)`, where every way a batch can go stale is
    /// enumerated, and every one of them costs the work rather than the render.
    ///
    /// The rows are ordered on the task's first turn rather than here, because
    /// this is reached from inside the list's height question, and ordering
    /// walks the data source.
    func beginRemeasuringOffscreenRows(at width: CGFloat) {
        task?.cancel()
        let merge: @MainActor @Sendable (Batch) -> Void = { [weak self] batch in
            self?.merge(batch, at: width)
        }
        task = Task { [weak self] in
            // A run superseded before its first turn walks nothing: the walk is
            // a data-source call per row, on the main actor.
            guard !Task.isCancelled,
                let stale = self?.staleRowsOutwardFromViewport(at: width), !stale.isEmpty
            else { return }
            await Self.remeasure(stale, at: width, merge: merge)
            // A cancelled run has already been replaced; clearing here would clear
            // its successor.
            guard !Task.isCancelled, let self else { return }
            task = nil
        }
    }

    /// Stale entries, each with the identity it is filed under.
    private typealias Batch = [(id: TranscriptRow.ID, entry: RowCache.Entry)]

    /// Everything a width change invalidated, in the order the list will want
    /// it: the rows on screen, then one below, one above, one below, out to both
    /// ends — the order the list's own idle re-measure walks in.
    ///
    /// One `rowAt` per row passed, until every stale entry has been claimed:
    /// what bounds it is how far the farthest measured row is from the viewport.
    /// Measured on ten thousand rows, all of them measured: **12 ms**, against
    /// the 1.9 s of measuring whose order it decides. Entries left over belong to
    /// rows the data source no longer has, and are dropped rather than measured.
    private func staleRowsOutwardFromViewport(at width: CGFloat) -> Batch {
        var pending = rowCache.entries(measuredAtWidthOtherThan: width)
        guard !pending.isEmpty, let owner else { return [] }
        let count = list.numberOfRows
        let visible = list.rows(in: list.bounds).clamped(to: 0..<count)

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
            } else if below < count, takesBelow || above < 0 {
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
            if let entry = pending.removeValue(forKey: id) { ordered.append((id, entry)) }
        }
        return ordered
    }

    /// How long a batch collects before it is filed: a frame at 60 Hz. Filing is
    /// a dictionary write per row, so this only keeps the hops to main few.
    private nonisolated static let batchInterval: UInt64 = 16_000_000

    /// How many rows are measured at once. Not a throughput knob: the task
    /// collecting the results is itself on the pool, and ten thousand runnable
    /// children would starve it — measured, it took 78 results in 10.8 s and the
    /// rest only once every child had finished.
    private nonisolated static let inFlightLimit = ProcessInfo.processInfo.activeProcessorCount

    /// The stale entries, re-measured concurrently, handed to `merge` a batch at
    /// a time. What crosses is `RowCache.Entry`, which is `Sendable` and carries
    /// its own recipe — so this is line-breaking and nothing else.
    private nonisolated static func remeasure(
        _ stale: Batch, at width: CGFloat, merge: @escaping @MainActor @Sendable (Batch) -> Void
    ) async {
        await withTaskGroup(of: (id: TranscriptRow.ID, entry: RowCache.Entry)?.self) { group in
            var next = 0
            func addNext() {
                guard next < stale.count else { return }
                let item = stale[next]
                next += 1
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    return (item.id, item.entry.remeasured(at: width))
                }
            }
            for _ in 0..<Swift.min(stale.count, inFlightLimit) { addNext() }

            var batch: Batch = []
            var opened = DispatchTime.now().uptimeNanoseconds
            for await result in group {
                addNext()
                guard let result else { continue }
                batch.append(result)
                guard DispatchTime.now().uptimeNanoseconds - opened >= batchInterval else { continue }
                await merge(batch)
                batch.removeAll(keepingCapacity: true)
                opened = DispatchTime.now().uptimeNanoseconds
            }
            if !batch.isEmpty { await merge(batch) }
        }
    }

    /// Files one batch, unless the width has moved on since it was measured.
    private func merge(_ batch: Batch, at width: CGFloat) {
        guard let owner, width == owner.contentWidth else { return }
        rowCache.merge(remeasured: batch, at: width)
    }
}
