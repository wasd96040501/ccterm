import AppKit

/// The question that stops a run: what the call will do, whole, and Allow /
/// Deny / Always Allow (01-run.md "Waiting for you"). Level with the run's
/// row, not indented like its items — it takes the column's full width.
@MainActor
final class ApprovalCardView: NSView, PageRowView {
    typealias Model = Approval

    weak var delegate: PageRowViewDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    static func height(for model: Approval, width: CGFloat) -> CGFloat { 120 }

    func configure(with model: Approval) {}
}
