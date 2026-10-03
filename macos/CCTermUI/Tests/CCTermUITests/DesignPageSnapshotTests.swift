import AppKit
import XCTest

@testable import CCTermDesign

/// The style page rendered off screen, whole, for review: a wide window and a
/// narrow one, light and dark, to `/tmp/ccterm-screenshots/Design-<width>-<scheme>.png`.
/// The window sits at (-30 000, -30 000) at alpha 0.01, so nothing shows on the
/// display. Skipped unless named: `make test-ui FILTER=DesignPageSnapshotTests`.
final class DesignPageSnapshotTests: XCTestCase {
    func testThePageFollowsTheWindowsWidth() throws {
        for width in [1240, 600] as [CGFloat] {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let image = try render(width: width, appearance: appearance)
                let url = URL(fileURLWithPath: "/tmp/ccterm-screenshots/Design-\(Int(width))-\(name).png")
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
                XCTAssertEqual(CGFloat(image.pixelsWide) / (image.size.width), 2, accuracy: 1.5)
            }
        }
    }

    /// The page at `width`, as tall as it is: laid out once at a window's
    /// height, then the window grown to the page's.
    private func render(width: CGFloat, appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
        let page = DesignPageViewController(sections: Design.sections())
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: 800), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = page
        window.setContentSize(NSSize(width: width, height: 800))
        window.orderFrontRegardless()
        defer { window.close() }
        window.layoutIfNeeded()
        let scroll = try XCTUnwrap(page.view as? NSScrollView)
        let height = try XCTUnwrap(scroll.documentView).fittingSize.height
        window.setContentSize(NSSize(width: width, height: max(height, 200)))
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        let view = scroll
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}
