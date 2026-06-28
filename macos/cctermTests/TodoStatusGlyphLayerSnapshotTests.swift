import AppKit
import XCTest

@testable import ccterm

/// Opt-in (filename ends in `SnapshotTests`; see CLAUDE.md) visual review of
/// the **AppKit** `TodoStatusGlyphLayer` — the replacement for the SwiftUI
/// `TodoStatusGlyph` (whose own snapshot lives in
/// `TodoStatusGlyphSnapshotTests` until the SwiftUI struct is deleted). Renders
/// each glyph by wrapping the bare layer-backed `NSView` in a throwaway VC and
/// driving `ViewSnapshot.renderViewController` (plan §9). Two PNGs:
///
///   - `.completed` (muted) at 10/11/12/13/14pt — confirms the ring band and
///     the inner dot share one antialiasing pass at every ship size (the
///     even-odd single-path raster the SwiftUI version was tuned for).
///   - one frame of live `.inProgress` (`muted: false`) — eyeball the dotted
///     ring (zero-length dashes + round caps render as dots).
@MainActor
final class TodoStatusGlyphLayerSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCompletedGlyphSizes() throws {
        let sizes: [CGFloat] = [10, 11, 12, 13, 14]
        let canvas = CGSize(width: 560, height: 90)
        let controller = makeRow(canvas: canvas) { container in
            self.layOutGlyphs(in: container, sizes: sizes) { side in
                let glyph = TodoStatusGlyphLayer()
                glyph.setState(.completed, muted: true)
                return glyph
            }
        }

        let image = ViewSnapshot.renderViewController(controller, size: canvas, settle: 0.4)
        let url = ViewSnapshot.writePNG(image, name: "TodoStatusGlyphLayer-completed")
        attach(url, name: "TodoStatusGlyphLayer-completed.png")

        XCTAssertGreaterThanOrEqual(image.size.width, 500)
    }

    func testLiveInProgressDottedRing() throws {
        let sizes: [CGFloat] = [10, 12, 14]
        let canvas = CGSize(width: 360, height: 90)
        let controller = makeRow(canvas: canvas) { container in
            self.layOutGlyphs(in: container, sizes: sizes) { side in
                let glyph = TodoStatusGlyphLayer()
                glyph.setState(.inProgress, muted: false)
                return glyph
            }
        }

        let image = ViewSnapshot.renderViewController(controller, size: canvas, settle: 0.4)
        let url = ViewSnapshot.writePNG(image, name: "TodoStatusGlyphLayer-inProgress")
        attach(url, name: "TodoStatusGlyphLayer-inProgress.png")

        XCTAssertGreaterThanOrEqual(image.size.width, 300)
    }

    // MARK: - Helpers

    /// A throwaway VC whose view is a `windowBackgroundColor` panel; `build`
    /// populates it with the glyph row.
    private func makeRow(
        canvas: CGSize, build: (NSView) -> Void
    ) -> NSViewController {
        let container = NSView(frame: NSRect(origin: .zero, size: canvas))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        build(container)
        let vc = NSViewController()
        vc.view = container
        return vc
    }

    /// Lay the glyphs out left-to-right, each centered vertically and pinned
    /// to its ship size via constraints (mirrors SwiftUI `.frame(w,h)`).
    private func layOutGlyphs(
        in container: NSView, sizes: [CGFloat], make: (CGFloat) -> TodoStatusGlyphLayer
    ) {
        var x: CGFloat = 24
        let spacing: CGFloat = 48
        for side in sizes {
            let glyph = make(side)
            container.addSubview(glyph)
            NSLayoutConstraint.activate([
                glyph.widthAnchor.constraint(equalToConstant: side),
                glyph.heightAnchor.constraint(equalToConstant: side),
                glyph.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                glyph.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: x),
            ])
            x += spacing
        }
    }

    private func attach(_ url: URL, name: String) {
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
