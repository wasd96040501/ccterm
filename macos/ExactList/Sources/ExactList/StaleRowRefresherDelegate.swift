import Foundation

/// What `StaleRowRefresher` asks of the list: refresh some stale rows within a
/// budget (SPEC W5).
@MainActor
protocol StaleRowRefresherDelegate: AnyObject {

    /// Measure stale rows in `refreshOrder` until `budget` is spent, with at
    /// least one row, then commit anchored and without animation. Returns
    /// whether stale rows remain.
    func staleRowRefresher(_ refresher: StaleRowRefresher, refreshRowsWithin budget: TimeInterval) -> Bool
}
