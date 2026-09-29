import AppKit

/// What an approval card shows the call will do, whole: a command in a
/// monospaced block after a `$`, or an edit as a compact diff — removed
/// lines on a red wash, added on a green one (design/transcript/01-run.md
/// "Waiting for you"). At most twelve lines; the card says when there are
/// more.
///
/// Drawn, not laid out from labels: a body's height is its lines' count, so
/// `measure` and `draw` share the same line metrics and cannot disagree.
@MainActor
final class ApprovalBodyView: NSView {
    static let maxLines = 12

    private static let commandFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let commandLine: CGFloat = 16
    /// `pre`'s padding: 8 above and below, 12 right, 24 left after the `$`.
    private static let commandInsets = NSEdgeInsets(top: 8, left: 24, bottom: 8, right: 12)
    private static let diffLine: CGFloat = 18
    private static let diffPadding: CGFloat = 4
    private static let diffTextInset: CGFloat = 14
    private static let radius: CGFloat = 6

    private var body: Approval.Body?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    func configure(body: Approval.Body) {
        self.body = body
        switch body {
        case .command(let text): setAccessibilityLabel(text)
        case .change(let removed, let added): setAccessibilityLabel((removed + added).joined(separator: "\n"))
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        needsDisplay = true
    }

    // MARK: - Measure

    /// The block's height at `width` — 0 when there is nothing to show — and
    /// whether lines beyond the twelfth were left out.
    static func measure(_ body: Approval.Body, width: CGFloat) -> (height: CGFloat, isCut: Bool) {
        switch body {
        case .command(let text):
            guard !text.isEmpty else { return (0, false) }
            let lines = commandLines(text, width: width)
            return (
                commandInsets.top + commandInsets.bottom + commandLine * CGFloat(min(lines, maxLines)),
                lines > maxLines
            )
        case .change(let removed, let added):
            let lines = removed.count + added.count
            guard lines > 0 else { return (0, false) }
            return (2 * diffPadding + diffLine * CGFloat(min(lines, maxLines)), lines > maxLines)
        }
    }

    private static func commandLines(_ text: String, width: CGFloat) -> Int {
        let available = max(1, width - commandInsets.left - commandInsets.right)
        let rect = commandString(text).boundingRect(
            with: NSSize(width: available, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        return max(1, Int((rect.height / commandLine).rounded(.up)))
    }

    private static func commandString(_ text: String, color: NSColor = .labelColor) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byCharWrapping
        style.minimumLineHeight = commandLine
        style.maximumLineHeight = commandLine
        return NSAttributedString(
            string: text, attributes: [.font: commandFont, .foregroundColor: color, .paragraphStyle: style])
    }

    private static func diffString(_ text: String, dimmed: Bool) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.minimumLineHeight = diffLine
        style.maximumLineHeight = diffLine
        return NSAttributedString(
            string: text.isEmpty ? " " : text,
            attributes: [
                .font: commandFont, .foregroundColor: NSColor.labelColor.withAlphaComponent(dimmed ? 0.55 : 1),
                .paragraphStyle: style,
            ])
    }

    // MARK: - Draw

    private static let addedWash = NSColor(name: nil) { appearance in
        NSColor.systemGreen.withAlphaComponent(
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.15 : 0.14)
    }

    private static let removedWash = NSColor(name: nil) { appearance in
        NSColor.systemRed.withAlphaComponent(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.14 : 0.10)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let body else { return }
        let block = NSBezierPath(roundedRect: bounds, xRadius: Self.radius, yRadius: Self.radius)
        NSColor.tertiarySystemFill.setFill()
        block.fill()
        switch body {
        case .command(let text): drawCommand(text)
        case .change(let removed, let added): drawChange(removed: removed, added: added, clip: block)
        }
    }

    private func drawCommand(_ text: String) {
        let insets = Self.commandInsets
        let line = Self.commandLine
        NSAttributedString(
            string: "$",
            attributes: [
                .font: Self.commandFont, .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: fixedLine(line),
            ]
        ).draw(in: NSRect(x: 10, y: insets.top, width: 12, height: line))
        let shown = min(Self.commandLines(text, width: bounds.width), Self.maxLines)
        let rect = NSRect(
            x: insets.left, y: insets.top, width: bounds.width - insets.left - insets.right,
            height: line * CGFloat(shown))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        Self.commandString(text).draw(
            with: rect, options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
    }

    private func fixedLine(_ height: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        return style
    }

    private func drawChange(removed: [String], added: [String], clip: NSBezierPath) {
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        let rows = (removed.map { ($0, true) } + added.map { ($0, false) }).prefix(Self.maxLines)
        for (index, row) in rows.enumerated() {
            let y = Self.diffPadding + Self.diffLine * CGFloat(index)
            (row.1 ? Self.removedWash : Self.addedWash).setFill()
            NSRect(x: 0, y: y, width: bounds.width, height: Self.diffLine).fill()
            NSColor.controlAccentColor.setFill()
            NSRect(x: 3, y: y, width: 3, height: Self.diffLine).fill()
            Self.diffString(row.0, dimmed: row.1).draw(
                with: NSRect(
                    x: Self.diffTextInset, y: y, width: max(0, bounds.width - Self.diffTextInset - 12),
                    height: Self.diffLine),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
