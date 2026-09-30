import AppKit

/// The question that stops a run: what the call will do, whole, and Allow /
/// Deny (01-run.md "Waiting for you"). Level with the run's row, not
/// indented like its items — it takes the column's full width. Outlined in
/// the separator colour with the user bubble's shape, not filled: it belongs
/// to the work, not to the reader yet.
///
/// Laid out by hand from `metrics`, which `height(for:width:)` reads too, so
/// the height a row declares and the card drawn in it are one computation.
@MainActor
final class ApprovalCardView: NSView, PageRowView {
    typealias Model = Approval

    weak var delegate: PageRowViewDelegate?

    private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static let reasonFont = NSFont.systemFont(ofSize: 12)
    private static let border: CGFloat = 1
    private static let padding = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
    private static let gap: CGFloat = 8
    private static let headHeight: CGFloat = 16
    private static let linkHeight: CGFloat = 16
    private static let buttonRow: CGFloat = 24
    private static let radius: CGFloat = 14

    private let outline = CALayer()
    private let tile = TileView()
    private let title = NSTextField(labelWithString: "")
    private let body = ApprovalBodyView()
    private let showAll = NSButton()
    private let reason = NSTextField(wrappingLabelWithString: "")
    private let deny = PillButton(title: String(localized: "Deny"), keys: "⎋")
    private let allow = PillButton(title: String(localized: "Allow"), keys: "⌘↩", isPrimary: true)

    private var model: Approval?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        outline.cornerRadius = Self.radius
        outline.borderWidth = Self.border
        layer?.addSublayer(outline)

        title.font = Self.titleFont
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        reason.font = Self.reasonFont
        reason.textColor = .secondaryLabelColor
        reason.lineBreakMode = .byWordWrapping

        showAll.isBordered = false
        showAll.attributedTitle = NSAttributedString(
            string: String(localized: "Show all"),
            attributes: [.font: Self.reasonFont, .foregroundColor: NSColor.linkColor])
        showAll.target = self
        showAll.action = #selector(showAllPressed)

        deny.keyEquivalent = "\u{1b}"
        deny.target = self
        deny.action = #selector(denyPressed)
        allow.keyEquivalent = "\r"
        allow.keyEquivalentModifierMask = .command
        allow.target = self
        allow.action = #selector(allowPressed)

        for view in [tile, title, body, showAll, reason, deny, allow] { addSubview(view) }
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    // MARK: - Metrics

    private struct Metrics {
        var bodyHeight: CGFloat
        var isCut: Bool
        var reasonHeight: CGFloat
        var height: CGFloat
    }

    private static func contentWidth(_ width: CGFloat) -> CGFloat {
        max(0, width - 2 * border - padding.left - padding.right)
    }

    private static func metrics(for model: Approval, width: CGFloat) -> Metrics {
        let content = contentWidth(width)
        let (bodyHeight, isCut) = model.body.map { ApprovalBodyView.measure($0, width: content) } ?? (0, false)
        var reasonHeight: CGFloat = 0
        if let text = model.reason, !text.isEmpty {
            let cell = NSTextFieldCell(textCell: text)
            cell.font = reasonFont
            cell.wraps = true
            cell.lineBreakMode = .byWordWrapping
            reasonHeight = ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: content, height: 100_000)).height)
        }
        var height = border + padding.top + headHeight
        if bodyHeight > 0 { height += gap + bodyHeight }
        if isCut { height += gap + linkHeight }
        if reasonHeight > 0 { height += gap + reasonHeight }
        height += gap + buttonRow + padding.bottom + border
        return Metrics(bodyHeight: bodyHeight, isCut: isCut, reasonHeight: reasonHeight, height: height)
    }

    static func height(for model: Approval, width: CGFloat) -> CGFloat {
        metrics(for: model, width: width).height
    }

    // MARK: - Model

    func configure(with model: Approval) {
        self.model = model
        tile.tile = model.tile
        title.stringValue = model.title
        if let content = model.body { body.configure(body: content) }
        reason.stringValue = model.reason ?? ""
        setAccessibilityElement(false)
        needsLayout = true
        needsDisplay = true
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        guard let model else { return }
        let metrics = Self.metrics(for: model, width: bounds.width)
        let inset = Self.border + Self.padding.left
        let content = Self.contentWidth(bounds.width)
        // The row is the card; its gap under the run is the transcript's (PageRow.spacingAbove).
        outline.frame = NSRect(x: 0, y: 0, width: bounds.width, height: metrics.height)

        var y = Self.border + Self.padding.top
        tile.frame.origin = NSPoint(x: inset, y: y)
        let titleX = inset + 16 + Self.gap
        let titleSize = title.fittingSize
        title.frame = NSRect(
            x: titleX, y: y + (Self.headHeight - titleSize.height) / 2, width: max(0, inset + content - titleX),
            height: titleSize.height)
        y += Self.headHeight

        body.isHidden = metrics.bodyHeight == 0
        if metrics.bodyHeight > 0 {
            y += Self.gap
            body.frame = NSRect(x: inset, y: y, width: content, height: metrics.bodyHeight)
            y += metrics.bodyHeight
        }
        showAll.isHidden = !metrics.isCut
        if metrics.isCut {
            y += Self.gap
            let size = showAll.fittingSize
            showAll.frame = NSRect(
                x: inset, y: y + (Self.linkHeight - size.height) / 2, width: size.width, height: size.height)
            y += Self.linkHeight
        }
        reason.isHidden = metrics.reasonHeight == 0
        if metrics.reasonHeight > 0 {
            y += Self.gap
            reason.frame = NSRect(x: inset, y: y, width: content, height: metrics.reasonHeight)
            y += metrics.reasonHeight
        }
        y += Self.gap
        var trailing = inset + content
        for button in [allow, deny] {
            let size = button.fittingSize
            button.frame = NSRect(
                x: trailing - size.width, y: y + (Self.buttonRow - size.height) / 2, width: size.width,
                height: size.height)
            trailing -= size.width + Self.gap
        }
    }

    // MARK: - Paint

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            outline.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Actions

    @objc private func allowPressed() { decide(.allow) }

    @objc private func denyPressed() { decide(.deny) }

    @objc private func showAllPressed() {
        guard let model else { return }
        delegate?.pageRowView(self, didRequestDocument: model.id, pinned: false)
    }

    private func decide(_ decision: Decision) {
        guard let model else { return }
        delegate?.pageRowView(self, didDecide: decision, forCall: model.id)
    }
}
