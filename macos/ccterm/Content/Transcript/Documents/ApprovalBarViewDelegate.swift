import AppKit

@MainActor
protocol ApprovalBarViewDelegate: AnyObject {
    /// The reader answered the call the bar asks about.
    func approvalBarView(_ approvalBar: ApprovalBarView, decide decision: Decision, for callID: String)
}
