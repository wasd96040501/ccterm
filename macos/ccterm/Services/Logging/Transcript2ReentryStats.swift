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

    private struct Counters {
        var blocks: Int = 0
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

    /// `tableView.didSet` with a non-nil table and non-empty blocks.
    /// Starts the attach-cycle timer and resets counters.
    static func recordAttachStart(blocks: Int) {
        guard enabled else { return }
        counters = Counters()
        counters.blocks = blocks
        attachStart = CFAbsoluteTimeGetCurrent()
    }

    /// First `markAnchorSettled` after `recordAttachStart` fires the
    /// summary line. Subsequent fires within the same cycle bump
    /// `anchorSettledFires` (so the duplicate-fire bug shows up in the
    /// summary without spamming the log).
    static func recordMarkAnchorSettled() {
        guard enabled else { return }
        counters.anchorSettledFires += 1
        guard counters.anchorSettledFires == 1 else { return }
        let totalMs = (CFAbsoluteTimeGetCurrent() - attachStart) * 1000
        let widthsStr = counters.invalidateWidths
            .map(String.init).joined(separator: ",")
        let line =
            "blocks=\(counters.blocks) "
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
}
