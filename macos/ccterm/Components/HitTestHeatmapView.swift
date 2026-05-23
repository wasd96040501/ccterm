import AppKit

/// Debug overlay that visualises AppKit's actual hit-test result for
/// every cell in its bounds. For each sample point it asks the parent
/// `hitTest(_:)` (skipping itself because `hitTest` returns nil) and
/// colors the cell by the winning view's identity. A legend in the
/// top-right corner names the views by class.
///
/// Intentionally inefficient — full grid re-sample on every layout —
/// because this is a build-time diagnostic, not shipping UI.
@MainActor
final class HitTestHeatmapView: NSView {
    override var isFlipped: Bool { true }

    /// Don't claim hits ourselves; we exist purely to visualise the
    /// hit-test the rest of the tree does.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Side of each sample cell. 8pt is a reasonable trade-off between
    /// fidelity and the cost of ~15k hit-tests per repaint on a 1200x800
    /// pane.
    private let cellSize: CGFloat = 8

    private let palette: [NSColor] = [
        .systemRed, .systemBlue, .systemGreen, .systemOrange,
        .systemPurple, .systemTeal, .systemPink, .systemYellow,
        .systemBrown, .systemMint, .systemIndigo, .systemCyan,
    ]

    /// Truncation budget for legend labels. Anything wider is
    /// middle-truncated so the legend box doesn't grow off-screen.
    private let maxLabelWidth: CGFloat = 320

    private var refreshTimer: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshTimer?.invalidate()
        guard window != nil else { return }
        // Periodic resample. Sidebar switch / session attach can swap
        // the transcript scroll view out from under us without firing
        // a layout pass on this overlay; a half-second tick is cheap
        // and keeps the heatmap honest.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) {
            [weak self] _ in
            self?.needsDisplay = true
        }
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    deinit {
        refreshTimer?.invalidate()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let parent = superview, let ctx = NSGraphicsContext.current?.cgContext
        else { return }

        var seen: [(view: NSView, color: NSColor)] = []
        func colorFor(_ v: NSView?) -> NSColor {
            guard let v else { return NSColor.black.withAlphaComponent(0.05) }
            if let existing = seen.first(where: { $0.view === v }) {
                return existing.color
            }
            let c = palette[seen.count % palette.count].withAlphaComponent(0.35)
            seen.append((v, c))
            return c
        }

        let cols = Int(ceil(bounds.width / cellSize))
        let rows = Int(ceil(bounds.height / cellSize))
        for j in 0..<rows {
            for i in 0..<cols {
                let localPoint = NSPoint(
                    x: CGFloat(i) * cellSize + cellSize / 2,
                    y: CGFloat(j) * cellSize + cellSize / 2)
                let parentPoint = convert(localPoint, to: parent)
                let hit = parent.hitTest(parentPoint)
                ctx.setFillColor(colorFor(hit).cgColor)
                ctx.fill(
                    NSRect(
                        x: CGFloat(i) * cellSize,
                        y: CGFloat(j) * cellSize,
                        width: cellSize, height: cellSize))
            }
        }

        drawLegend(seen: seen, in: ctx)
    }

    private func drawLegend(seen: [(view: NSView, color: NSColor)], in _: CGContext) {
        let entries: [(label: String, color: NSColor)] =
            seen.map { (label: classChain(for: $0.view), color: $0.color) }
            + [(label: "nil (no hit)", color: NSColor.black.withAlphaComponent(0.4))]

        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let padding: CGFloat = 6
        let swatchSize: CGFloat = 12
        let lineHeight: CGFloat = 16

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]

        // Compute a label column width that's the smaller of the widest
        // label and our truncation budget — short legends still get a
        // snug box, but pathological mangled SwiftUI class names cap out.
        let widestLabel = entries.map {
            ($0.label as NSString).size(withAttributes: attrs).width
        }.max() ?? 200
        let labelColumnWidth = min(widestLabel, maxLabelWidth)

        let boxWidth = padding + swatchSize + 6 + labelColumnWidth + padding
        let boxHeight = padding * 2 + CGFloat(entries.count) * lineHeight
        let boxOrigin = CGPoint(x: bounds.width - boxWidth - 12, y: 12)
        let box = NSRect(origin: boxOrigin, size: CGSize(width: boxWidth, height: boxHeight))

        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        box.fill()
        NSColor.separatorColor.setStroke()
        box.frame(withWidth: 0.5)

        for (i, entry) in entries.enumerated() {
            let y = box.minY + padding + CGFloat(i) * lineHeight
            let swatch = NSRect(
                x: box.minX + padding,
                y: y + (lineHeight - swatchSize) / 2,
                width: swatchSize, height: swatchSize)
            // Solid swatch (no alpha) so it stays readable against the
            // legend box's own background.
            entry.color.withAlphaComponent(1).setFill()
            swatch.fill()
            NSColor.separatorColor.setStroke()
            swatch.frame(withWidth: 0.5)

            let labelRect = NSRect(
                x: swatch.maxX + 6,
                y: y,
                width: labelColumnWidth,
                height: lineHeight)
            (entry.label as NSString).draw(
                with: labelRect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: attrs,
                context: nil)
        }
    }

    /// Compose a "BlockCellView ← Transcript2TableView ← NSScrollView…"
    /// trail so the legend tells the user which view in the hierarchy
    /// is the actual hit-test winner, not just its leaf class.
    private func classChain(for view: NSView) -> String {
        var parts: [String] = []
        var current: NSView? = view
        var depth = 0
        while let v = current, depth < 4 {
            parts.append(NSStringFromClass(type(of: v)).replacingOccurrences(of: "ccterm.", with: ""))
            current = v.superview
            depth += 1
            if current === self.superview { break }
        }
        return parts.joined(separator: " ← ")
    }
}
