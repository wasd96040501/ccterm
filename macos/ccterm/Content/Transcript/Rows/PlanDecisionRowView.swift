import AppKit

/// **Keep Planning** / **Approve** (⌘↩) under a plan waiting for the reader
/// (07-talk.md "ExitPlanMode").
@MainActor
final class PlanDecisionRowView: NSView, PageRowView {
    typealias Model = Plan

    weak var delegate: PageRowViewDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    static func height(for model: Plan, width: CGFloat) -> CGFloat { 32 }

    func configure(with model: Plan) {}
}
