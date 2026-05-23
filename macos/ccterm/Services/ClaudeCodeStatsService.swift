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
/// detached background task; the cached `result` is written back on
/// the main actor. Concurrent `refresh()` calls coalesce — a fresh
/// request cancels the in-flight task and starts a new one.
@Observable
@MainActor
final class ClaudeCodeStatsService {
    private(set) var result: ClaudeCodeStats.Result?

    /// Last completed aggregation timestamp. Used as a `.task(id:)`
    /// signal so card views can re-arm animations when fresh data
    /// lands, without diff-ing the heavy `Result` struct itself.
    private(set) var lastUpdated: Date?

    private var refreshTask: Task<Void, Never>?

    init() {}

    /// Kick off (or restart) a background aggregation. Cheap to call
    /// repeatedly — earlier in-flight work is cancelled.
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let aggregated = await Task.detached(priority: .userInitiated) {
                ClaudeCodeStats.aggregate()
            }.value
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.result = aggregated
            self.lastUpdated = Date()
        }
    }
}
