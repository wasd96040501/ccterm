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
    weak var owner: StaleRowRefresherOwner?

    init() {
        fatalError("unimplemented: SPEC W5")
    }

    /// Schedules the next batch for an idle turn. Calling again before it runs
    /// cancels the one pending, as a width change does.
    func schedule() {
        fatalError("unimplemented: SPEC W5")
    }

    /// Drops the pending batch, if any.
    func cancel() {
        fatalError("unimplemented: SPEC W5")
    }
}
