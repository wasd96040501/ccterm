import AppKit

/// What `MotionAnimator` reports: that a commit's animations ended (SPEC U8,
/// M10).
@MainActor
protocol MotionAnimatorOwner: AnyObject {

    /// Every animation of one commit has ended. `retired` are its containers
    /// that no longer belong in the mounted set: removed rows, and rows whose
    /// sweep has left `P`.
    func motionAnimator(_ animator: MotionAnimator, didFinishCommitRetiring retired: [RowContainerView])
}
