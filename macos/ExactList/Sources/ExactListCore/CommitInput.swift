import Foundation

/// Everything a commit is planned from (SPEC §7, §8.2). The engine fills it
/// in; `CommitPlanner` reads nothing else.
public struct CommitInput: Equatable, Sendable {

    /// The geometry before the batch.
    public var oldHeights: RowHeights

    /// The geometry after it: the old heights carried through `map`, with every
    /// inserted, noted and freshly measured row answered at the current width.
    public var newHeights: RowHeights

    /// What the batch did to the numbering. For a width, viewport or spacing
    /// change it is the identity.
    public var map: RowIndexMap

    /// The viewport before the batch.
    public var oldViewport: Viewport

    /// The viewport after it, with the offset not yet decided. It differs from
    /// `oldViewport` only for V1 and V2.
    public var newViewport: Viewport

    /// The batch's policy (§6.1).
    public var anchoring: Anchoring

    /// `automaticallyFollowsTail`.
    public var followsTail: Bool

    /// W2: rescale a row anchor's distance, because the width changed.
    public var rescalesAnchor: Bool

    /// The rows mounted before the commit, in the old numbering. Removed rows
    /// animate out only if they were mounted, and P1 keeps a row mounted while
    /// its sweep crosses `P`.
    public var mountedRows: IndexSet

    /// M1: whether the commit animates. When it doesn't, every motion's start
    /// equals its end.
    public var animates: Bool

    public init(
        oldHeights: RowHeights, newHeights: RowHeights, map: RowIndexMap, oldViewport: Viewport,
        newViewport: Viewport, anchoring: Anchoring, followsTail: Bool, rescalesAnchor: Bool,
        mountedRows: IndexSet, animates: Bool
    ) {
        self.oldHeights = oldHeights
        self.newHeights = newHeights
        self.map = map
        self.oldViewport = oldViewport
        self.newViewport = newViewport
        self.anchoring = anchoring
        self.followsTail = followsTail
        self.rescalesAnchor = rescalesAnchor
        self.mountedRows = mountedRows
        self.animates = animates
    }
}
