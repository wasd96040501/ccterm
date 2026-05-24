import Foundation
import Observation

/// In-process cache + async re-computer around `ClaudeCodeStats.aggregate`.
///
/// `result` is `nil` only on a fresh-launch first read; once the first
/// aggregation finishes it stays populated for the lifetime of the
/// app. Re-opening the New Session card therefore never shows an empty
/// state — the cards bind to the cached value and the next `refresh()`
/// folds new data in with a `.default` animation (driven by the call
/// site, not here).
///
/// Aggregation reads dozens of JSONL files from disk, so it runs on a
/// dedicated user-initiated GCD queue (not a Swift `Task.detached`,
/// which inherits actor isolation in subtle ways — the GCD queue
/// guarantees the heavy work never lands on the main thread). The
/// cached `result` is written back on the main actor.
///
/// Concurrent `refresh()` calls overlap on the serial queue (each
/// request enqueues a fresh aggregation); the most recent result wins
/// when it lands on the main actor. There's no in-flight cancellation
/// hook because the work is dominated by `FileManager.contentsOfFile`
/// reads that don't observe `Task.isCancelled` anyway — running an
/// extra aggregation is cheap.
@Observable
final class ClaudeCodeStatsService {
    @MainActor private(set) var result: ClaudeCodeStats.Result?

    /// Last completed aggregation timestamp. Used as a `.task(id:)`
    /// signal so card views can re-arm animations when fresh data
    /// lands, without diff-ing the heavy `Result` struct itself.
    @MainActor private(set) var lastUpdated: Date?

    /// Serial GCD queue — fans out the aggregation off the main
    /// thread without going through Swift Concurrency's actor
    /// inheritance rules. `.userInitiated` matches the user-visible
    /// nature of the work (the New Session view is waiting on it).
    private static let workQueue = DispatchQueue(
        label: "ccterm.ClaudeCodeStatsService", qos: .userInitiated)

    init() {}

    /// Kick off a background aggregation. Cheap to call repeatedly;
    /// overlapping calls just enqueue and the most recent result wins.
    nonisolated func refresh() {
        Self.workQueue.async { [weak self] in
            let aggregated = ClaudeCodeStats.aggregate()
            Task { @MainActor [weak self] in
                self?.result = aggregated
                self?.lastUpdated = Date()
            }
        }
    }
}
