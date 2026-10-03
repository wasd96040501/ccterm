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

    /// The most a capture holds: the window server's images stop at 16 384 px,
    /// 8 192 pt at 2×, and the page is taller; so a long page is captured in
    /// bands of this height, scrolled under a window of it, and joined.
    private static let band: CGFloat = 4000

    /// The page at `width`, as tall as it is: laid out once at a window's
    /// height, then the window grown to the page's — or, past one band, held at
    /// a band's height and scrolled.
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
        let height = max(try XCTUnwrap(scroll.documentView).fittingSize.height, 200)
        guard height > Self.band else {
            window.setContentSize(NSSize(width: width, height: height))
            window.layoutIfNeeded()
            // Past the scrollers' flash on first showing.
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
            return try await CompositedCapture.image(of: window)
        }
        // A scroller would show in every band.
        scroll.hasVerticalScroller = false
        window.setContentSize(NSSize(width: width, height: Self.band))
        window.layoutIfNeeded()
        var bands: [(origin: CGFloat, image: CGImage)] = []
        var origin: CGFloat = 0
        while origin < height {
            // The last band ends where the page does, overlapping the one before.
            let top = min(origin, height - Self.band)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: top))
            scroll.reflectScrolledClipView(scroll.contentView)
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
            bands.append((top, try await CompositedCapture.image(of: window)))
            origin += Self.band
        }
        let scale = CGFloat(bands[0].image.width) / width
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: bands[0].image.width, height: Int((height * scale).rounded()), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for (top, image) in bands {
            let y = (height - top - Self.band) * scale
            context.draw(image, in: CGRect(x: 0, y: y, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return try XCTUnwrap(context.makeImage())
    }
}
