import AppKit

/// What `MotionAnimator` reports: that a commit's motion ended (SPEC U8, M10),
/// and where an animated scroll is (S3).
@MainActor
protocol MotionAnimatorOwner: AnyObject {

    /// One commit's motion has ended. `retired` are its containers that no
    /// longer belong in the mounted set: removed rows, and rows whose sweep has
    /// left `P`.
    func motionAnimator(_ animator: MotionAnimator, didFinishCommitRetiring retired: [RowContainerView])

    /// One frame of an animated scroll: the clip view goes to `offset`, as a
    /// scroll does (P1, W4).
    func motionAnimator(_ animator: MotionAnimator, scrollTo offset: CGFloat)
}
