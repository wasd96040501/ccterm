import Foundation

/// Refreshes stale rows on idle run loop turns, 4 ms at a time, until none are
/// left (SPEC W5).
///
/// It owns only the scheduling. What is stale, and in which order, is
/// `StaleRows`'s; measuring and committing are the list's.
@MainActor
final class StaleRowRefresher {

    /// W5's per-turn budget.
    static let budget: TimeInterval = 0.004

    /// Weak: the list owns this.
    weak var delegate: StaleRowRefresherDelegate?

    /// Bumped by every `schedule()` and `cancel()`, so a batch already queued
    /// by an earlier call sees it has been superseded and does nothing.
    private var generation = 0

    init() {}

    /// Schedules the next batch for an idle turn. Calling again before it runs
    /// cancels the one pending, as a width change does.
    func schedule() {
        generation += 1
        let scheduled = generation
        // The default mode only: not during a live resize or a scroll gesture,
        // whose tracking modes are exactly the turns that aren't idle.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == scheduled, let delegate = self.delegate else { return }
                if delegate.refreshStaleRows(within: Self.budget), self.generation == scheduled {
                    self.schedule()
                }
            }
        }
    }

    /// Drops the pending batch, if any.
    func cancel() {
        generation += 1
    }
}
