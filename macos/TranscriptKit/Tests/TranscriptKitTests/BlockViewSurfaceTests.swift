import AppKit
import XCTest

@testable import TranscriptKit

/// The two things AppKit used to do for free, and now does not.
///
/// A row's painting lives on a `CALayer` put there by hand, so that a hover band
/// can be composited *under* the glyphs — sublayers land above `contents`, so the
/// glyphs have to move off `contents` for anything to get beneath them. The price
/// is that the layer is no longer AppKit's to maintain: it keeps its own layer's
/// `contentsScale` in step with the display and resizes it with the view, and it
/// does neither for a layer it did not create.
///
/// Both failures are invisible to every other assertion here and loud on screen —
/// a whole transcript rendered at 1× on a Retina display, or content stretched
/// because the surface kept a stale size. Exactly the kind of thing that gets
/// noticed three weeks later and blamed on something else.
///
/// Read through `layer.sublayers` rather than through any hook added for the
/// purpose: the surface *is* a sublayer, so its scale and its frame are already
/// observable from outside.
@MainActor
final class BlockViewSurfaceTests: XCTestCase {

    private struct Mounted {
        let window: NSWindow
        let cell: BlockView
    }

    private func mount(_ source: String, width: CGFloat = 400) -> Mounted {
        NSApplication.shared.setActivationPolicy(.prohibited)

        let block = MarkdownBlockBuilder.make(source).measure(width)
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: block.size.height),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.alphaValue = 0.01
        // As in the other mounts here: `NSWindow` predates ARC and defaults to
        // releasing itself on close, which would over-release the reference this
        // test still holds.
        window.isReleasedWhenClosed = false

        let cell = BlockView()
        cell.frame = NSRect(x: 0, y: 0, width: width, height: block.size.height)
        window.contentView?.addSubview(cell)
        cell.configure(with: block)
        window.orderFront(nil)
        cell.layoutSubtreeIfNeeded()
        cell.display()

        return Mounted(window: window, cell: cell)
    }

    /// Every layer the row's painting lives on. The hover band is a
    /// `CAShapeLayer` and is deliberately not one of these.
    private func surfaces(_ mounted: Mounted) -> [CALayer] {
        (mounted.cell.layer?.sublayers ?? []).filter { !($0 is CAShapeLayer) }
    }

    // MARK: - Where the cut goes

    private func hover(_ mounted: Mounted, at point: CGPoint) {
        let event = NSEvent.mouseEvent(
            with: .mouseMoved, location: mounted.cell.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: mounted.window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0)!
        mounted.cell.mouseMoved(with: event)
    }

    private static func firstLinkPoint(in block: MeasuredBlock) -> CGPoint? {
        for y in stride(from: 0, to: block.size.height, by: 3) {
            for x in stride(from: 0, to: block.size.width, by: 3) {
                let point = CGPoint(x: x, y: y)
                if block.link(at: point) != nil { return point }
            }
        }
        return nil
    }

    /// The common case pays nothing for the mechanism. Prose paints nothing at
    /// `.background` behind its text, so "under the glyphs" and "under everything"
    /// are the same place and a second surface would be an empty bitmap the size
    /// of the row.
    func testProseDoesNotSplitForABand() throws {
        let mounted = mount("some words with [a link](https://example.com) in them")
        defer { mounted.window.close() }

        let point = try XCTUnwrap(
            Self.firstLinkPoint(
                in: MarkdownBlockBuilder.make(
                    "some words with [a link](https://example.com) in them"
                ).measure(400)))
        hover(mounted, at: point)

        XCTAssertEqual(surfaces(mounted).count, 1, "prose split when there was nothing to separate")
        XCTAssertTrue(
            mounted.cell.layer?.sublayers?.first is CAShapeLayer,
            "the band is not at the bottom, where prose can afford to put it")
    }

    /// A table paints row tints at `.background`, so the band has something to be
    /// *above* as well as below — which is the case the cut exists for. Splitting
    /// puts it between the two, rather than under the tints where it would be
    /// veiled by them.
    func testATableSplitsAndTakesTheBandBetweenTheHalves() throws {
        let source = "| h1 | h2 |\n|----|----|\n| plain | [word](https://example.com) |"
        let mounted = mount(source)
        defer { mounted.window.close() }

        XCTAssertEqual(surfaces(mounted).count, 1, "a row nobody has hovered should not be split")

        let point = try XCTUnwrap(
            Self.firstLinkPoint(in: MarkdownBlockBuilder.make(source).measure(400)))
        hover(mounted, at: point)

        XCTAssertEqual(surfaces(mounted).count, 2, "the table did not split for the band")

        let sublayers = try XCTUnwrap(mounted.cell.layer?.sublayers)
        XCTAssertEqual(sublayers.count, 3, "expected under, band, over")
        XCTAssertFalse(sublayers[0] is CAShapeLayer, "nothing is painted under the band")
        XCTAssertTrue(sublayers[1] is CAShapeLayer, "the band is not between the two surfaces")
        XCTAssertFalse(sublayers[2] is CAShapeLayer)
    }

    /// And it folds back. A split that outlived the band it was made for would
    /// leave every hovered table row carrying a second bitmap for good.
    func testTheSplitFoldsBackWhenTheBandGoes() throws {
        let source = "| h1 | h2 |\n|----|----|\n| plain | [word](https://example.com) |"
        let mounted = mount(source)
        defer { mounted.window.close() }

        let point = try XCTUnwrap(
            Self.firstLinkPoint(in: MarkdownBlockBuilder.make(source).measure(400)))
        hover(mounted, at: point)
        XCTAssertEqual(surfaces(mounted).count, 2)

        // Rebinding takes the band away outright, with no fade to wait on.
        mounted.cell.configure(with: MarkdownBlockBuilder.make("plain words").measure(400))

        XCTAssertEqual(surfaces(mounted).count, 1, "the row stayed split after the band went")
        XCTAssertEqual(mounted.cell.layer?.sublayers?.count, 1)
    }

    // MARK: - What AppKit no longer maintains

    func testASurfaceIsAtTheWindowsBackingScale() throws {
        let mounted = mount("a paragraph of ordinary words")
        defer { mounted.window.close() }

        let surface = try XCTUnwrap(surfaces(mounted).first, "the row has no surface to draw on")
        XCTAssertEqual(
            surface.contentsScale, mounted.window.backingScaleFactor,
            "the surface is not at the display's scale, so the row renders soft")
    }

    /// The surface is congruent with the view by definition — it is the view's
    /// painting. Nothing about that is maintained by autoresizing, so a frame
    /// change has to reach it.
    func testASurfaceFollowsTheViewsSize() throws {
        let mounted = mount("a paragraph of ordinary words")
        defer { mounted.window.close() }

        mounted.cell.setFrameSize(NSSize(width: 250, height: 120))
        mounted.cell.layoutSubtreeIfNeeded()

        let surface = try XCTUnwrap(surfaces(mounted).first)
        XCTAssertEqual(surface.frame, mounted.cell.bounds, "the surface kept a stale size")
    }

    /// The row's painting reaches the surface at all — which is the claim the move
    /// off `draw(_:)` rests on, and the one that would fail silently as a blank
    /// row rather than as an error.
    func testTheRowsPaintingReachesTheSurface() throws {
        let mounted = mount("a paragraph of ordinary words")
        defer { mounted.window.close() }

        let cell = mounted.cell
        let rep = try XCTUnwrap(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
        cell.cacheDisplay(in: cell.bounds, to: rep)

        var inked = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                if let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.1 { inked += 1 }
            }
        }
        XCTAssertGreaterThan(inked, 0, "the row rasterised to nothing at all")
    }
}
