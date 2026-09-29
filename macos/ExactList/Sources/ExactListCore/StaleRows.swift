import Foundation

/// The rows whose height was measured at a width other than the current one,
/// and the order in which they get refreshed (SPEC §9).
public struct StaleRows: Equatable, Sendable {

    /// No stale rows, over `count` rows.
    public init(count: Int) {
        fatalError("unimplemented: SPEC W3")
    }

    public var isEmpty: Bool {
        fatalError("unimplemented: SPEC W5")
    }

    public func contains(_ row: Int) -> Bool {
        fatalError("unimplemented: SPEC W4")
    }

    /// W3: a width change makes every row stale except `fresh`, the rows just
    /// measured at the new width.
    public mutating func markAllStale(except fresh: IndexSet) {
        fatalError("unimplemented: SPEC W3")
    }

    /// Rows measured at the current width.
    public mutating func markFresh(_ rows: IndexSet) {
        fatalError("unimplemented: SPEC W4, W5")
    }

    /// Renumbers through a batch. Inserted rows arrive fresh (U5) and removed
    /// rows drop out.
    public mutating func apply(_ map: RowIndexMap) {
        fatalError("unimplemented: SPEC W5")
    }

    /// W5: up to `limit` stale rows, nearest to `anchor` first, alternating
    /// down and up.
    public func refreshOrder(around anchor: Int, limit: Int) -> [Int] {
        fatalError("unimplemented: SPEC W5")
    }
}
