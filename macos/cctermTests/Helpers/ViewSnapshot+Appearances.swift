import AppKit
import XCTest

@testable import ccterm

extension ViewSnapshot {
    /// Renders a view controller in light and dark, side by side — one PNG per
    /// state — for a human to look at. `make` builds a fresh controller for
    /// each appearance.
    @MainActor
    static func renderLightAndDark(
        _ make: () -> NSViewController, size: CGSize, name: String
    ) -> NSImage {
        let images = [NSAppearance.Name.aqua, .darkAqua].map { appearance -> NSImage in
            let controller = make()
            controller.view.appearance = NSAppearance(named: appearance)
            return renderViewController(controller, size: size)
        }
        let gap: CGFloat = 12
        let sheet = NSImage(size: NSSize(width: size.width * 2 + gap, height: size.height))
        sheet.lockFocus()
        NSColor.gray.setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        images[0].draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
        images[1].draw(at: NSPoint(x: size.width + gap, y: 0), from: .zero, operation: .copy, fraction: 1)
        sheet.unlockFocus()
        return sheet
    }

    /// Stacks the sheets of several states into one PNG and writes it.
    @MainActor
    @discardableResult
    static func writeStack(_ sheets: [NSImage], name: String) -> URL {
        let gap: CGFloat = 12
        let width = sheets.map(\.size.width).max() ?? 0
        let height = sheets.map(\.size.height).reduce(0, +) + gap * CGFloat(max(0, sheets.count - 1))
        let stack = NSImage(size: NSSize(width: width, height: height))
        stack.lockFocus()
        NSColor.gray.setFill()
        NSRect(origin: .zero, size: stack.size).fill()
        var y = height
        for sheet in sheets {
            y -= sheet.size.height
            sheet.draw(at: NSPoint(x: 0, y: y), from: .zero, operation: .copy, fraction: 1)
            y -= gap
        }
        stack.unlockFocus()
        return writePNG(stack, name: name)
    }
}
