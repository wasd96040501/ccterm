import Foundation
import os

/// In-memory aggregator for session-switch re-entry perf measurement.
///
/// Hot-path call sites (`heightOfRow`, `viewFor`, `tableFrameDidChange`,
/// `invalidate(rows:)`) push counts and durations via plain `var`
/// increments — no `os_log`, no `appLog`, no `Task`. One summary line
/// is emitted via `os.Logger` at `recordMarkAnchorSettled`, capturing
/// the whole attach cycle.
///
/// Why a dedicated aggregator: per-event `os_log` adds ~12% of N ms of
/// measurement bias to the attach (the unified-logging ring stalls the
/// producer under high write rate). Aggregating in-process and emitting
/// once removes that bias — the numbers we then read out reflect real
/// layout cost, not our scaffold.
///
/// Off by default. `CCTermApp.init` flips `enabled = true` in DEBUG so
/// the summary lands in `os_log` under `category=Transcript2Reentry`.
@MainActor
enum Transcript2ReentryStats {
    /// Single-process flag. `nonisolated(unsafe)` because hot-path
    /// readers (heightOfRow etc.) run on MainActor by contract; no
    /// cross-thread writes.
    nonisolated(unsafe) static var enabled: Bool = false

    private static let logger = Logger(
        subsystem: "com.ccterm.app", category: "Transcript2Reentry")

    private static var counters = Counters()
    private static var attachStart: CFAbsoluteTime = 0
    /// Set in `recordDetach`, cleared in `recordAttachStart` after the
    /// gap is folded into the next cycle's counters. Lets the static
    /// aggregator pair a detach (old coordinator's `tableView = nil`)
    /// with the next attach (new coordinator's `tableView = newTable`)
    /// across instances — they're the two ends of the SwiftUI rebuild
    /// gap on session switch.
    private static var detachStart: CFAbsoluteTime = 0
    /// Gates `recordMarkAnchorSettled` from emitting a summary when no
    /// `recordAttachStart` ran for the current cycle. The empty-session
    /// attach branch in `tableView.didSet` skips `recordAttachStart`,
    /// but `markAnchorSettled` still fires via the firstTile path; without
    /// this gate the summary line carries stale counters and a garbage
    /// `t_attach_ms` (CFAbsoluteTime relative to uninitialised 0).
    private static var attachInProgress: Bool = false

    private struct Counters {
        var blocks: Int = 0
        /// -1 = no prior detach (first attach in process lifetime).
        var detachGapMs: Double = -1
        var heightOfRowCached: Int = 0
        var heightOfRowUncached: Int = 0
        var heightOfRowUncachedTotalMs: Double = 0
        var heightOfRowUncachedMaxMs: Double = 0
        var viewForCached: Int = 0
        var viewForUncached: Int = 0
        var frameDidChangeReal: Int = 0
        var frameDidChangeShortCircuit: Int = 0
        var invalidateCount: Int = 0
        var invalidateTotalMs: Double = 0
        var invalidateWidths: [Int] = []
        var firstTileFires: Int = 0
        var anchorSettledFires: Int = 0
    }

    // MARK: - Lifecycle markers

    /// Old coordinator's `tableView` weak ref is being cleared
    /// (`Transcript2NSViewBridge.dismantleNSView`). Stamps the start of the
    /// SwiftUI rebuild gap. Pairs with the next process-wide
    /// `recordAttachStart` (on a *different* coordinator instance).
    static func recordDetach() {
        guard enabled else { return }
        detachStart = CFAbsoluteTimeGetCurrent()
    }

    /// `tableView.didSet` with a non-nil table and non-empty blocks.
    /// Starts the attach-cycle timer and resets counters. Folds the
    /// detach→attach gap into the new cycle's counters so the summary
    /// line carries both segments of the white-screen window.
    static func recordAttachStart(blocks: Int) {
        guard enabled else { return }
        counters = Counters()
        counters.blocks = blocks
        attachStart = CFAbsoluteTimeGetCurrent()
        if detachStart > 0 {
            counters.detachGapMs = (attachStart - detachStart) * 1000
            detachStart = 0
        }
        attachInProgress = true
    }

    /// First `markAnchorSettled` after `recordAttachStart` fires the
    /// summary line. Subsequent fires within the same cycle bump
    /// `anchorSettledFires` (so the duplicate-fire bug shows up in the
    /// summary without spamming the log). Empty-session attaches that
    /// reach `markAnchorSettled` through the firstTile path without a
    /// matching `recordAttachStart` are dropped — their counters are
    /// stale carry-over from the prior cycle.
    static func recordMarkAnchorSettled() {
        guard enabled else { return }
        guard attachInProgress else { return }
        counters.anchorSettledFires += 1
        guard counters.anchorSettledFires == 1 else { return }
        attachInProgress = false
        let totalMs = (CFAbsoluteTimeGetCurrent() - attachStart) * 1000
        let widthsStr = counters.invalidateWidths
            .map(String.init).joined(separator: ",")
        let gapStr =
            counters.detachGapMs >= 0
            ? String(format: "%.1f", counters.detachGapMs) : "-1"
        let line =
            "blocks=\(counters.blocks) "
            + "detach_gap_ms=\(gapStr) "
            + "t_attach_ms=\(String(format: "%.1f", totalMs)) "
            + "heightOfRow_uncached=\(counters.heightOfRowUncached) "
            + "heightOfRow_cached=\(counters.heightOfRowCached) "
            + "heightOfRow_total_ms=\(String(format: "%.2f", counters.heightOfRowUncachedTotalMs)) "
            + "heightOfRow_max_ms=\(String(format: "%.2f", counters.heightOfRowUncachedMaxMs)) "
            + "viewFor_uncached=\(counters.viewForUncached) "
            + "viewFor_cached=\(counters.viewForCached) "
            + "frameDidChange_real=\(counters.frameDidChangeReal) "
            + "frameDidChange_short=\(counters.frameDidChangeShortCircuit) "
            + "invalidate_count=\(counters.invalidateCount) "
            + "invalidate_total_ms=\(String(format: "%.2f", counters.invalidateTotalMs)) "
            + "invalidate_widths=[\(widthsStr)] "
            + "firstTile_fires=\(counters.firstTileFires) "
            + "anchorSettled_fires=\(counters.anchorSettledFires)"
        logger.info("reentry-summary \(line, privacy: .public)")
    }

    // MARK: - Hot-path counters (pure Swift writes, no logging)

    static func recordHeightOfRow(cached: Bool, ms: Double) {
        guard enabled else { return }
        if cached {
            counters.heightOfRowCached += 1
        } else {
            counters.heightOfRowUncached += 1
            counters.heightOfRowUncachedTotalMs += ms
            if ms > counters.heightOfRowUncachedMaxMs {
                counters.heightOfRowUncachedMaxMs = ms
            }
        }
    }

    static func recordViewFor(cached: Bool) {
        guard enabled else { return }
        if cached {
            counters.viewForCached += 1
        } else {
            counters.viewForUncached += 1
        }
    }

    static func recordFrameDidChange(shortCircuit: Bool) {
        guard enabled else { return }
        if shortCircuit {
            counters.frameDidChangeShortCircuit += 1
        } else {
            counters.frameDidChangeReal += 1
        }
    }

    static func recordInvalidate(width: CGFloat, ms: Double) {
        guard enabled else { return }
        counters.invalidateCount += 1
        counters.invalidateTotalMs += ms
        counters.invalidateWidths.append(Int(width.rounded()))
    }

    static func recordHandleFirstTile() {
        guard enabled else { return }
        counters.firstTileFires += 1
    }

    // MARK: - Test-only accessors

    #if DEBUG
    /// Read-only view of the current cycle's counters. Used by unit tests
    /// to verify that the placeholder→real frame cascade did or did not
    /// trigger the row-invalidate / heightOfRow paths we expect to
    /// suppress. Production reads come through the os.Logger summary line
    /// emitted at `recordMarkAnchorSettled` — there is no production
    /// caller for this snapshot.
    struct Snapshot {
        let blocks: Int
        let detachGapMs: Double
        let heightOfRowCached: Int
        let heightOfRowUncached: Int
        let viewForCached: Int
        let viewForUncached: Int
        let frameDidChangeReal: Int
        let frameDidChangeShortCircuit: Int
        let invalidateCount: Int
        let invalidateWidths: [Int]
        let firstTileFires: Int
        let anchorSettledFires: Int
        let attachInProgress: Bool
    }

    static func snapshot() -> Snapshot {
        Snapshot(
            blocks: counters.blocks,
            detachGapMs: counters.detachGapMs,
            heightOfRowCached: counters.heightOfRowCached,
            heightOfRowUncached: counters.heightOfRowUncached,
            viewForCached: counters.viewForCached,
            viewForUncached: counters.viewForUncached,
            frameDidChangeReal: counters.frameDidChangeReal,
            frameDidChangeShortCircuit: counters.frameDidChangeShortCircuit,
            invalidateCount: counters.invalidateCount,
            invalidateWidths: counters.invalidateWidths,
            firstTileFires: counters.firstTileFires,
            anchorSettledFires: counters.anchorSettledFires,
            attachInProgress: attachInProgress)
    }

    /// Wipe all per-cycle state. Tests call this in `setUp` so each
    /// scenario starts from a clean slate; production never resets
    /// outside of `recordAttachStart`.
    static func reset() {
        counters = Counters()
        attachStart = 0
        detachStart = 0
        attachInProgress = false
    }
    #endif
}
