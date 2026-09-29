import AppKit
import XCTest

@testable import ccterm

/// Renders row views one under another, each at the height it declares, the
/// way the transcript stacks them — light above dark, one column per width —
/// to `/tmp/ccterm-screenshots/<name>.png` for review, attached to `test`.
enum RowSnapshot {
    /// `rows` are configured models; `prepare` may put a view in a state
    /// paint alone can't reach (hover). `gap` is the space between rows.
    @MainActor
    static func render<V: PageRowView>(
        _ type: V.Type, _ rows: [V.Model], widths: [CGFloat] = [520], gap: CGFloat = 10, name: String,
        prepare: (V, Int) -> Void = { _, _ in }, test: XCTestCase
    ) {
        let inset: CGFloat = 24
        var columns: [(light: NSView, dark: NSView)] = []
        for width in widths {
            let heights = rows.map { V.height(for: $0, width: width) }
            let height = heights.reduce(0, +) + gap * CGFloat(max(0, rows.count - 1)) + 2 * inset
            let panels = [NSAppearance.Name.aqua, .darkAqua].map { appearance -> NSView in
                let panel = FlippedView(frame: NSRect(x: 0, y: 0, width: width + 2 * inset, height: height))
                panel.appearance = NSAppearance(named: appearance)
                panel.wantsLayer = true
                panel.appearance?.performAsCurrentDrawingAppearance {
                    panel.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                }
                var y = inset
                for (index, model) in rows.enumerated() {
                    let view = V()
                    view.frame = NSRect(x: inset, y: y, width: width, height: heights[index])
                    panel.addSubview(view)
                    view.configure(with: model)
                    prepare(view, index)
                    y += heights[index] + gap
                }
                return panel
            }
            columns.append((panels[0], panels[1]))
        }
        let tallest = columns.map(\.light.frame.height).max() ?? 0
        let size = NSSize(width: columns.map(\.light.frame.width).reduce(0, +), height: 2 * tallest)
        let root = FlippedView(frame: NSRect(origin: .zero, size: size))
        var x: CGFloat = 0
        for column in columns {
            column.light.frame.size.height = tallest
            column.dark.frame.size.height = tallest
            column.light.setFrameOrigin(NSPoint(x: x, y: 0))
            column.dark.setFrameOrigin(NSPoint(x: x, y: size.height / 2))
            root.addSubview(column.light)
            root.addSubview(column.dark)
            x += column.light.frame.width
        }
        let controller = NSViewController()
        controller.view = root
        let image = ViewSnapshot.renderViewController(controller, size: size)
        let url = ViewSnapshot.writePNG(image, name: name)
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.lifetime = .keepAlways
        test.add(attachment)
        XCTAssertEqual(image.size, size)
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}
