import CoreGraphics

/// One row's part in a commit: where it starts and ends, on screen and in
/// height (SPEC M2).
///
/// Screen tops are `y − o`: the document position less the offset in force at
/// that end. The presented value at progress `p` is
/// `end + (start − end)·(1 − p)`, with the amplitude already applied (M7).
public struct RowMotion: Equatable, Sendable {

    public enum Kind: Equatable, Sendable {
        case surviving
        case inserted
        case removed
        case moved
    }

    public var kind: Kind

    /// The row's index: new numbering, or old numbering for `.removed`.
    public var row: Int

    public var startTop: CGFloat
    public var endTop: CGFloat
    public var startHeight: CGFloat
    public var endHeight: CGFloat

    /// The effect of an inserted or removed row; empty otherwise (M9).
    public var transition: RowTransition

    public init(
        kind: Kind, row: Int, startTop: CGFloat, endTop: CGFloat, startHeight: CGFloat,
        endHeight: CGFloat, transition: RowTransition
    ) {
        self.kind = kind
        self.row = row
        self.startTop = startTop
        self.endTop = endTop
        self.startHeight = startHeight
        self.endHeight = endHeight
        self.transition = transition
    }

    /// Whether anything moves. A commit adds no animation for a row where this
    /// is `false`.
    public var isStill: Bool {
        switch kind {
        case .inserted, .removed:
            return false
        case .surviving, .moved:
            return startTop == endTop && startHeight == endHeight
        }
    }
}
