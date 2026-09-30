import AppKit

/// **Keep Planning** / **Approve** (⌘↩) under a plan waiting for the reader
/// (07-talk.md "ExitPlanMode").
@MainActor
final class PlanDecisionRowView: NSView, PageRowView {
    /// The plan's call id — what a decision answers.
    typealias Model = String

    weak var delegate: PageRowViewDelegate?

    private let keepPlanning = PillButton(title: String(localized: "Keep Planning"))
    private let approve = PillButton(title: String(localized: "Approve"), keys: "⌘↩", isPrimary: true)
    private var callID: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        approve.keyEquivalent = "\r"
        approve.keyEquivalentModifierMask = .command
        for button in [keepPlanning, approve] {
            button.target = self
        }
        keepPlanning.action = #selector(keepPlanningClicked)
        approve.action = #selector(approveClicked)

        let stack = NSStackView(views: [keepPlanning, approve])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    static func height(for model: String, width: CGFloat) -> CGFloat { 32 }

    func configure(with model: String) {
        callID = model
    }

    @objc private func keepPlanningClicked() {
        guard let callID else { return }
        delegate?.rowView(self, decide: .keepPlanning, for: callID)
    }

    @objc private func approveClicked() {
        guard let callID else { return }
        delegate?.rowView(self, decide: .approvePlan, for: callID)
    }
}
