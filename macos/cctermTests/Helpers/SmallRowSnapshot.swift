import AppKit
import XCTest

@testable import ccterm

/// Renders a column of one row view's models, light above dark, each row at
/// the height it declares and the width of a transcript column — for visual
/// review (`/tmp/ccterm-screenshots/<name>.png`).
@MainActor
enum SmallRowSnapshot {
    static let padding: CGFloat = 16
    static let gap: CGFloat = 10

    static func render<V: PageRowView>(
        _ models: [V.Model], of type: V.Type, name: String, width: CGFloat = 520
    ) -> (
        NSImage, URL
    ) {
        func panel(_ appearance: NSAppearance.Name) -> NSView {
            let heights = models.map { V.height(for: $0, width: width) }
            let total = heights.reduce(0, +) + gap * CGFloat(max(models.count - 1, 0)) + 2 * padding
            let panel = NSView(frame: NSRect(x: 0, y: 0, width: width + 2 * padding, height: total))
            panel.appearance = NSAppearance(named: appearance)
            panel.wantsLayer = true
            panel.appearance?.performAsCurrentDrawingAppearance {
                panel.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            var top = padding
            for (model, height) in zip(models, heights) {
                let view = V()
                view.frame = NSRect(x: padding, y: total - top - height, width: width, height: height)
                view.configure(with: model)
                panel.addSubview(view)
                view.layoutSubtreeIfNeeded()
                top += height + gap
            }
            return panel
        }
        let light = panel(.aqua)
        let dark = panel(.darkAqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: light.frame.width, height: light.frame.height * 2))
        dark.setFrameOrigin(NSPoint(x: 0, y: light.frame.height))
        root.addSubview(light)
        root.addSubview(dark)
        let controller = NSViewController()
        controller.view = root
        let image = ViewSnapshot.renderViewController(controller, size: root.frame.size)
        return (image, ViewSnapshot.writePNG(image, name: name))
    }
}
