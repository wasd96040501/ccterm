import CoreGraphics

/// Every row's height, the spacing between rows, and the index that answers
/// geometry queries (SPEC §5).
///
/// Row `i`'s top is `Σ_{k<i} h(k) + i·s` (G1), found through a Fenwick index
/// over the heights, so a query and a height change are O(log n) (G5). A
/// structural change rebuilds the whole value, which is O(n) and happens at
/// commit, once per batch.
///
/// The spacing is kept apart from the sums, so changing it (V3) touches no
/// entry.
public struct RowHeights: Equatable, Sendable {

    /// `s`, the gap between two adjacent rows.
    public var spacing: CGFloat

    /// Builds the index in O(n). Every height must be finite and > 0 (L12).
    public init(_ heights: [CGFloat] = [], spacing: CGFloat = 0) {
        fatalError("unimplemented: SPEC G1")
    }

    /// `n`.
    public var count: Int {
        fatalError("unimplemented: SPEC G1")
    }

    /// `h(row)`.
    public subscript(row: Int) -> CGFloat {
        fatalError("unimplemented: SPEC G1")
    }

    /// The heights in row order: what the next commit rebuilds from.
    public var values: [CGFloat] {
        fatalError("unimplemented: SPEC G1")
    }

    /// `H`: `Σ h + (n − 1)·s`, or 0 for no rows (G2).
    public var contentHeight: CGFloat {
        fatalError("unimplemented: SPEC G2")
    }

    /// `y(row)` (G1). O(log n).
    public func top(ofRow row: Int) -> CGFloat {
        fatalError("unimplemented: SPEC G1")
    }

    /// The row whose `[y, y + h)` contains `y`, or `nil` when `y` falls in a
    /// spacing gap or outside the content (G4). O(log n).
    public func row(containingY y: CGFloat) -> Int? {
        fatalError("unimplemented: SPEC G4")
    }

    /// The smallest `a` with `y(a) + h(a) > y`: the first row not entirely
    /// above `y` (A1). `nil` when every row is above it. O(log n).
    public func firstRow(endingBelow y: CGFloat) -> Int? {
        fatalError("unimplemented: SPEC A1")
    }

    /// The rows whose frames intersect the document interval `[lower, upper]`
    /// (G4, P1). O(log n).
    public func rows(intersecting lower: CGFloat, _ upper: CGFloat) -> Range<Int> {
        fatalError("unimplemented: SPEC G4")
    }

    /// Changes one row's height. O(log n) (G5).
    public mutating func setHeight(_ height: CGFloat, ofRow row: Int) {
        fatalError("unimplemented: SPEC G5")
    }
}
