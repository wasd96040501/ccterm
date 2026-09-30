import CoreGraphics

/// A commit's outcome: everything the engine applies, decided in one place
/// (SPEC §6, §7, §8.2).
public struct CommitPlan: Equatable, Sendable {

    /// The geometry to install: `CommitInput.newHeights`, unchanged.
    public var heights: RowHeights

    /// `o'`: restored, then clamped (A6, A7).
    public var offset: CGFloat

    /// The anchor as restored, after renumbering (A4, A5) and rescaling (W2).
    var anchor: ScrollAnchor

    /// Every row that is mounted during or after the commit (P1), with its
    /// start and end. Rows that don't move appear too, with start equal to end.
    public var motions: [RowMotion]

    /// `k` (M7), already applied to every motion's start. 1 when nothing was
    /// capped.
    var amplitude: CGFloat

    /// A8 after the commit.
    public var isFollowingTail: Bool

    init(
        heights: RowHeights, offset: CGFloat, anchor: ScrollAnchor, motions: [RowMotion],
        amplitude: CGFloat, isFollowingTail: Bool
    ) {
        self.heights = heights
        self.offset = offset
        self.anchor = anchor
        self.motions = motions
        self.amplitude = amplitude
        self.isFollowingTail = isFollowingTail
    }
}
