import AppKit

/// The gutter beside a ``SourceView``'s text, Xcode's: line numbers right
/// aligned, none on a removed line, each changed line's tint carried across,
/// and a striped bar at the leading edge beside every change.
///
/// A plain view beside the scroll view rather than its `NSRulerView`: from
/// macOS 26 a ruler floats over the clip view, and the text under it stopped
/// reaching the screen (composited blank while `cacheDisplay` drew it).
/// Positions are read from the text view by conversion, so the gutter needs
/// only to redraw when the text scrolls.
@MainActor
final class SourceGutterView: NSView {
    private weak var sourceTextView: SourceTextView?
    private(set) var thickness: CGFloat = 30

    /// Xcode's gutter numbers: smaller than the text, figures of one width.
    static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    /// Room for the change bar at the leading edge.
    private static let leadingInset: CGFloat = 10
    /// Between the numbers and the text.
    private static let trailingInset: CGFloat = 6
    private static let barWidth: CGFloat = 3
    private static let barInset: CGFloat = 2

    init(textView: SourceTextView) {
        sourceTextView = textView
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    /// Wide enough for the largest number the document shows.
    func updateThickness() {
        let largest = sourceTextView?.lines.lazy.compactMap(\.number).max() ?? 0
        let digits = max(2, String(largest).count)
        let digit = ("8" as NSString).size(withAttributes: [.font: Self.numberFont]).width
        thickness = ceil(Self.leadingInset + CGFloat(digits) * digit + Self.trailingInset)
    }

    override func draw(_ rect: NSRect) {
        guard let textView = sourceTextView else { return }
        SourceTheme.background.setFill()
        rect.fill()
        // Only the vertical extent carries over: the gutter sits beside the text.
        let converted = convert(rect, to: textView)
        let visible = textView.lineIndexes(
            in: NSRect(x: 0, y: converted.minY, width: textView.bounds.width, height: converted.height))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.numberFont, .foregroundColor: SourceTheme.lineNumber,
        ]
        let width = bounds.width - Self.trailingInset
        for index in visible {
            let line = textView.lines[index]
            let lineRect = convert(textView.rect(ofLine: index), from: textView)
            if let tint = SourceView.tint(for: line.change) {
                tint.setFill()
                NSRect(x: 0, y: lineRect.minY, width: bounds.width, height: lineRect.height).fill()
            }
            guard let number = line.number,
                let baseline = textView.baseline(ofLine: index, descent: -(textView.plainFont.descender))
            else { continue }
            let y = convert(NSPoint(x: 0, y: baseline), from: textView).y
            let label = String(number) as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: width - size.width, y: y - Self.numberFont.ascender), withAttributes: attributes)
        }
        drawChangeBars(for: visible, in: textView)
    }

    /// One bar per run of changed lines, the height of the run.
    private func drawChangeBars(for visible: Range<Int>, in textView: SourceTextView) {
        guard !visible.isEmpty else { return }
        var index = visible.lowerBound
        let lines = textView.lines
        // A run that began above the viewport still draws from its start.
        while index > 0, lines[index].isChange, lines[index - 1].isChange { index -= 1 }
        while index < visible.upperBound {
            guard lines[index].isChange else {
                index += 1
                continue
            }
            let start = index
            while index < lines.count, lines[index].isChange { index += 1 }
            let top = convert(textView.rect(ofLine: start), from: textView).minY
            let bottom = convert(textView.rect(ofLine: index - 1), from: textView).maxY
            drawBar(NSRect(x: Self.barInset, y: top + 1, width: Self.barWidth, height: max(0, bottom - top - 2)))
        }
    }

    /// Xcode's uncommitted-change bar: a rounded blue bar with lighter
    /// diagonal stripes.
    private func drawBar(_ rect: NSRect) {
        guard rect.height > 0 else { return }
        let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width / 2, yRadius: rect.width / 2)
        SourceTheme.changeBar.setFill()
        shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let stripes = NSBezierPath()
        stripes.lineWidth = 1
        var y = rect.minY - rect.width
        while y < rect.maxY {
            stripes.move(to: NSPoint(x: rect.minX, y: y + rect.width))
            stripes.line(to: NSPoint(x: rect.maxX, y: y))
            y += 3
        }
        SourceTheme.changeBarStripe.setStroke()
        stripes.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

extension SourceLine {
    fileprivate var isChange: Bool { change == .added || change == .removed }
}
