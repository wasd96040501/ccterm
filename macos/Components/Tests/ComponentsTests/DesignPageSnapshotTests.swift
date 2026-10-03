import AppKit
import XCTest

@testable import ComponentsDesign

/// The style page rendered whole, for review: a wide window and a narrow one,
/// light and dark, to `/tmp/ccterm-screenshots/Design-<width>-<scheme>.png`.
/// As the window server composites it (`CompositedCapture`), so selections and
/// materials look as they do on screen; the window hangs off the screen's
/// corner with one point showing and never takes the key. Skipped unless
/// named: `make test-ui FILTER=DesignPageSnapshotTests`.
@MainActor
final class DesignPageSnapshotTests: XCTestCase {
    func testThePageFollowsTheWindowsWidth() async throws {
        for width in [1240, 600] as [CGFloat] {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let image = try await render(width: width, appearance: appearance)
                let url = URL(fileURLWithPath: "/tmp/ccterm-screenshots/Design-\(Int(width))-\(name).png")
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let rep = NSBitmapImageRep(cgImage: image)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
                XCTAssertEqual(CGFloat(image.width), width * 2, accuracy: 1, "the page is the window's width")
            }
        }
    }

    /// The page at `width`, as tall as it is: laid out once at a window's
    /// height, then the window grown to the page's.
    private func render(width: CGFloat, appearance: NSAppearance.Name) async throws -> CGImage {
        let page = DesignPageViewController(sections: Design.sections())
        let window = CompositedCapture.mount(
            page, size: NSSize(width: width, height: 800), appearance: NSAppearance(named: appearance))
        defer {
            window.contentViewController = nil
            window.close()
        }
        window.layoutIfNeeded()
        let scroll = try XCTUnwrap(page.view as? NSScrollView)
        let height = try XCTUnwrap(scroll.documentView).fittingSize.height
        window.setContentSize(NSSize(width: width, height: max(height, 200)))
        window.layoutIfNeeded()
        // Past the scrollers' flash on first showing.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
        return try await CompositedCapture.image(of: window)
    }
}
