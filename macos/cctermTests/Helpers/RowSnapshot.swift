import AppKit
import XCTest

@testable import ccterm

/// Renders row views one under another, the way the transcript stacks them,
/// light above dark, to `/tmp/ccterm-screenshots/<name>.png` for review.
enum RowSnapshot {
    /// `rows` are configured models; `prepare` may put a view in a state
    /// paint alone can't reach (hover). `gap` is the transcript's row spacing.
    @MainActor
    static func render<V: PageRowView>(
        _ type: V.Type, _ rows: [V.Model], width: CGFloat, gap: CGFloat = 6, name: String,
        prepare: (V, Int) -> Void = { _, _ in }, test: XCTestCase
    ) {
        let heights = rows.map { V.height(for: $0, width: width) }
        let inset: CGFloat = 24
        let panelHeight = heights.reduce(0, +) + gap * CGFloat(max(0, rows.count - 1)) + 2 * inset
        let size = NSSize(width: width + 2 * inset, height: panelHeight)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height * 2))
        for (index, appearance) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            let panel = NSView(
                frame: NSRect(x: 0, y: CGFloat(1 - index) * size.height, width: size.width, height: size.height))
            panel.appearance = NSAppearance(named: appearance)
            panel.wantsLayer = true
            panel.appearance?.performAsCurrentDrawingAppearance {
                panel.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            var y = size.height - inset
            for (row, model) in rows.enumerated() {
                y -= heights[row]
                let view = V()
                view.frame = NSRect(x: inset, y: y, width: width, height: heights[row])
                panel.addSubview(view)
                view.configure(with: model)
                prepare(view, row)
                y -= gap
            }
            root.addSubview(panel)
        }
        let controller = NSViewController()
        controller.view = root
        let image = ViewSnapshot.renderViewController(controller, size: root.frame.size)
        let url = ViewSnapshot.writePNG(image, name: name)
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.lifetime = .keepAlways
        test.add(attachment)
        XCTAssertEqual(image.size, root.frame.size)
    }
}
