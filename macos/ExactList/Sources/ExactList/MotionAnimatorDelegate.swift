import AppKit

/// What `MotionAnimator` reports: that a commit's motion ended (SPEC M10), and
/// where an animated scroll is (S3).
@MainActor
protocol MotionAnimatorDelegate: AnyObject {

    /// One commit's motion has ended. `retired` are the containers of the rows
    /// it moved out, which no longer belong in the mounted set.
    func motionAnimator(_ animator: MotionAnimator, didFinishCommitRetiring retired: [ListRowView])

    /// One frame of an animated scroll: the clip view goes to `offset`, as a
    /// scroll does (P1, W4).
    func motionAnimator(_ animator: MotionAnimator, didRequestScrollTo offset: CGFloat)
}
