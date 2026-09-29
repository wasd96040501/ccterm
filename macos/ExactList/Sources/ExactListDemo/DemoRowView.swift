import AppKit

/// One demo row: a block of wrapped text on a rounded card, with a disclosure
/// that expands it. Its height comes from `height(for:width:)`, from the same
/// constants its layout uses.
final class DemoRowView: NSView {

    /// Reports a press on the disclosure: the host toggles its model and
    /// commits anchored on this row (A2).
    var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.title = ""
        disclosure.target = self
        disclosure.action = #selector(toggle)
        addSubview(disclosure)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    static func height(for text: String, expanded: Bool, width: CGFloat) -> CGFloat {
        let shown = Self.shown(text, expanded: expanded)
        return ceil(textBounds(shown, width: textWidth(in: width)).height) + 2 * Layout.padding
    }

    func configure(text: String, expanded: Bool) {
        self.text = Self.shown(text, expanded: expanded)
        disclosure.state = expanded ? .on : .off
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        disclosure.frame = NSRect(
            x: Layout.margin + Layout.padding, y: Layout.padding, width: Layout.disclosure, height: Layout.disclosure)
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: Layout.margin, dy: 0)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: card, xRadius: 8, yRadius: 8).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()
        let width = Self.textWidth(in: bounds.width)
        let origin = NSPoint(x: card.minX + Layout.padding + Layout.disclosure + Layout.gap, y: Layout.padding)
        Self.attributed(text).draw(
            with: NSRect(origin: origin, size: NSSize(width: width, height: bounds.height)),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .group
    }

    override func accessibilityLabel() -> String? {
        text
    }

    // MARK: - Private

    /// The one set of numbers both the layout and `height(for:…)` read.
    private enum Layout {
        static let margin: CGFloat = 10
        static let padding: CGFloat = 10
        static let disclosure: CGFloat = 16
        static let gap: CGFloat = 6
        static let font = NSFont.systemFont(ofSize: 13)
    }

    private let disclosure = NSButton()

    private var text = ""

    @objc private func toggle() {
        onToggle?()
    }

    /// Collapsed, a row shows its first line; expanded, all of it.
    private static func shown(_ text: String, expanded: Bool) -> String {
        expanded ? text : String(text.prefix { $0 != "\n" })
    }

    private static func textWidth(in width: CGFloat) -> CGFloat {
        max(1, width - 2 * Layout.margin - 2 * Layout.padding - Layout.disclosure - Layout.gap)
    }

    private static func attributed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: Layout.font, .foregroundColor: NSColor.labelColor])
    }

    /// The typesetter `draw(_:)` uses, asked for the height alone.
    private static func textBounds(_ text: String, width: CGFloat) -> NSRect {
        attributed(text).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}
