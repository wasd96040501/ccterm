import AppKit

/// `stop.circle` *Interrupted*: the reader stopped Claude while it was
/// writing — the reply's last word (05-local.md "Interruption").
@MainActor
final class InterruptionRowView: NSView, PageRowView {
    typealias Model = Void

    weak var delegate: PageRowViewDelegate?

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: String(localized: "Interrupted"))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.image = .symbol("stop.circle", pointSize: 11)
        icon.contentTintColor = .tertiaryLabelColor
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [icon, label])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    static func height(for model: Void, width: CGFloat) -> CGFloat { 20 }

    func configure(with model: Void) {}
}
