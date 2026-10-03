import AppKit
import DisplayModels

/// Under the jump bar of a document whose call waits for the reader: *Claude
/// wants to run this command* · the reason · **Deny** / **Allow** — the same
/// buttons and keys as the card in the transcript; answering either answers
/// both (02-command.md "Live").
@MainActor
public final class ApprovalBarView: NSView {
    public weak var delegate: ApprovalBarViewDelegate?

    private var callID: String?

    private lazy var tileView: TileView = {
        let tile = TileView()
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.setContentHuggingPriority(.required, for: .horizontal)
        return tile
    }()

    private lazy var requestLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12.5, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        return label
    }()

    private lazy var reasonLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12.5)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private lazy var row: NSStackView = {
        let denyButton = PillButton(title: String(localized: "Deny", bundle: .module))
        denyButton.target = self
        denyButton.action = #selector(deny)
        denyButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // ⌘↩ answers it, as the card's does.
        let allowButton = PillButton(title: String(localized: "Allow", bundle: .module), isPrimary: true)
        allowButton.target = self
        allowButton.action = #selector(allow)
        allowButton.keyEquivalent = "\r"
        allowButton.keyEquivalentModifierMask = .command
        allowButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [tileView, requestLabel, reasonLabel, denyButton, allowButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let separator = CALayer()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(separator)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
    }

    public convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor =
                NSColor.textBackgroundColor.blended(withFraction: 0.09, of: NSColor.sidebarCoral)?.cgColor
            separator.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    public override func layout() {
        super.layout()
        separator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 0.5)
    }

    /// The tile, `request`, `reason`; the buttons answer `approval.id`.
    public func configure(with approval: Approval) {
        callID = approval.id
        tileView.tile = approval.tile
        requestLabel.stringValue = approval.request
        reasonLabel.stringValue = approval.reason ?? ""
        needsDisplay = true
    }

    @objc private func deny() {
        guard let callID else { return }
        delegate?.approvalBarView(self, didDecide: .deny, forCall: callID)
    }

    @objc private func allow() {
        guard let callID else { return }
        delegate?.approvalBarView(self, didDecide: .allow, forCall: callID)
    }
}
