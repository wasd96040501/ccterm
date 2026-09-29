import AppKit

/// **Keep Planning** / **Approve** (⌘↩) under a plan waiting for the reader
/// (07-talk.md "ExitPlanMode").
@MainActor
final class PlanDecisionRowView: NSView, PageRowView {
    /// The plan's call id — what a decision answers.
    typealias Model = String

    weak var delegate: PageRowViewDelegate?

    private let keepPlanning = PillButton(primary: false)
    private let approve = PillButton(primary: true)
    private var callID: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        keepPlanning.setTitle(String(localized: "Keep Planning"))
        approve.setTitle(String(localized: "Approve"), keys: "⌘↩")
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

    /// The design's `.btn`: a 22-pt pill, 13-pt title, a quaternary fill and a
    /// hairline ring — or, primary, the accent colour under white ink.
    private final class PillButton: NSButton {
        private let isPrimary: Bool

        init(primary: Bool) {
            isPrimary = primary
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            isBordered = false
            wantsLayer = true
            layer?.cornerRadius = 11
            layer?.borderWidth = primary ? 0 : 0.5
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        /// `keys` follows the title dimmed and a size smaller, as the design's `kbd`.
        func setTitle(_ title: String, keys: String? = nil) {
            let ink: NSColor = isPrimary ? .white : .labelColor
            let text = NSMutableAttributedString(
                string: title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: ink])
            if let keys {
                text.append(
                    NSAttributedString(
                        string: " " + keys,
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: ink.withAlphaComponent(0.7),
                        ]))
            }
            attributedTitle = text
            invalidateIntrinsicContentSize()
        }

        override var intrinsicContentSize: NSSize {
            NSSize(width: ceil(attributedTitle.size().width) + 28, height: 22)
        }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let fill: NSColor = isPrimary ? .controlAccentColor : .quaternarySystemFill
                let shade = isPrimary ? NSColor.black : .labelColor
                layer?.backgroundColor =
                    (isHighlighted ? fill.blended(withFraction: 0.15, of: shade) ?? fill : fill).cgColor
                layer?.borderColor = NSColor.separatorColor.cgColor
            }
        }

        override var isHighlighted: Bool {
            didSet { needsDisplay = true }
        }
    }
}
