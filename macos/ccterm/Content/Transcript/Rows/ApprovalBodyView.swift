import AppKit
import Components

/// What an approval card shows the call will do, whole: a command in a
/// monospaced block after a `$`, or an edit as a compact diff drawn as a
/// document's is — removed lines on a red wash, added on a green one, the
/// change bar down the leading edge; a new file's bar is green
/// (design/transcript/01-run.md "Waiting for you"). At most twelve lines;
/// the card says when there are more.
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
    /// Where the change bar stands, as in a document's gutter.
    private static let diffBarX: CGFloat = 2
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
        case .newFile(let lines): setAccessibilityLabel(lines.joined(separator: "\n"))
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
            return measureDiff(lines: removed.count + added.count)
        case .newFile(let lines):
            return measureDiff(lines: lines.count)
        }
    }

    private static func measureDiff(lines: Int) -> (height: CGFloat, isCut: Bool) {
        guard lines > 0 else { return (0, false) }
        return (2 * diffPadding + diffLine * CGFloat(min(lines, maxLines)), lines > maxLines)
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

    private static func diffString(_ text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.minimumLineHeight = diffLine
        style.maximumLineHeight = diffLine
        return NSAttributedString(
            string: text.isEmpty ? " " : text,
            attributes: [
                .font: commandFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
            ])
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        guard let body else { return }
        let block = NSBezierPath(roundedRect: bounds, xRadius: Self.radius, yRadius: Self.radius)
        NSColor.tertiarySystemFill.setFill()
        block.fill()
        switch body {
        case .command(let text): drawCommand(text)
        case .change(let removed, let added):
            drawDiff(
                removed.map { ($0, NSColor.removedLineWash) } + added.map { ($0, .addedLineWash) }, bar: .hunks,
                clip: block)
        case .newFile(let lines):
            drawDiff(lines.map { ($0, NSColor.addedLineWash) }, bar: .wholeFile, clip: block)
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

    /// Every line is a change, so the bar is one run down all of them.
    private func drawDiff(_ lines: [(text: String, wash: NSColor)], bar: ChangeBar, clip: NSBezierPath) {
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        let shown = lines.prefix(Self.maxLines)
        for (index, line) in shown.enumerated() {
            let y = Self.diffPadding + Self.diffLine * CGFloat(index)
            line.wash.setFill()
            NSRect(x: 0, y: y, width: bounds.width, height: Self.diffLine).fill()
            Self.diffString(line.text).draw(
                with: NSRect(
                    x: Self.diffTextInset, y: y, width: max(0, bounds.width - Self.diffTextInset - 12),
                    height: Self.diffLine),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        bar.draw(
            NSRect(
                x: Self.diffBarX, y: Self.diffPadding, width: ChangeBar.width,
                height: Self.diffLine * CGFloat(shown.count)),
            joinsAbove: false, joinsBelow: false)
        NSGraphicsContext.restoreGraphicsState()
    }
}
