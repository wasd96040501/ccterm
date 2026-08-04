import AppKit
import XCTest

@testable import TranscriptKit

/// Finding a link under a point, and turning a press on one into an activation.
///
/// Two halves, and the seam between them is the interesting part. The block tree
/// answers *where* a link is — every container forwarding the point into its own
/// space, which is the thing that used to be re-projected by hand — and
/// `BlockView` decides *whether a press was a click*, which is state and
/// therefore the view's.
@MainActor
final class LinkActivationTests: XCTestCase {

    private func measured(_ source: String, width: CGFloat = 400) -> MeasuredBlock {
        MarkdownBlockBuilder.make(source).measure(width)
    }

    /// A point on the ink of a block whose whole content is one link.
    private func onTheLink(_ block: MeasuredBlock) throws -> CGPoint {
        let rect = try XCTUnwrap(block.fullRects().first)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    // MARK: - Where the link is

    func testLinkIsFoundUnderItsOwnGlyphs() throws {
        let block = measured("[word](https://example.com)")
        XCTAssertEqual(try block.link(at: onTheLink(block))?.url.absoluteString, "https://example.com")
    }

    /// `index(at:)` clamps — a point past the end of a line resolves to that
    /// line's last character — so without the containment check every click to
    /// the right of a link would open it.
    func testNoLinkInTheEmptySpaceBesideOne() throws {
        let block = measured("[word](https://example.com)")
        let rect = try XCTUnwrap(block.fullRects().first)
        XCTAssertNil(block.link(at: CGPoint(x: rect.maxX + 60, y: rect.midY)))
        XCTAssertNil(block.link(at: CGPoint(x: rect.midX, y: rect.maxY + 40)))
    }

    func testPlainTextHasNoLink() throws {
        let block = measured("just words")
        XCTAssertNil(block.link(at: try onTheLink(block)))
    }

    // MARK: - Every container forwards it
    //
    // Each of these puts the link behind a different offset. A container that
    // forgot to subtract its own would answer `nil`, or — worse — answer for the
    // wrong run.

    func testBlockquoteForwardsThePoint() throws {
        let block = measured("> [word](https://example.com)")
        XCTAssertNotNil(block.link(at: try onTheLink(block)))
    }

    func testListItemForwardsThePointPastItsMarker() throws {
        let block = measured("- [word](https://example.com)")
        XCTAssertNotNil(block.link(at: try onTheLink(block)))
    }

    func testNestedContainersCompose() throws {
        let block = measured("> - [word](https://example.com)")
        XCTAssertNotNil(block.link(at: try onTheLink(block)))
    }

    /// A table's rectangles are cell bands rather than runs of glyphs, so the
    /// point is taken just inside the cell's leading padding — which is where the
    /// link's own glyph sits.
    func testTableCellForwardsThePoint() throws {
        let block = measured("| h |\n|---|\n| [word](https://example.com) |")
        let cell = try XCTUnwrap(block.fullRects().last)
        XCTAssertNotNil(block.link(at: CGPoint(x: cell.minX + 10, y: cell.midY)))
    }

    /// A list marker is furniture: it holds no link, and a point on it is left of
    /// the content entirely.
    func testMarkerColumnHoldsNoLink() throws {
        let block = measured("- [word](https://example.com)")
        let rect = try XCTUnwrap(block.fullRects().first)
        XCTAssertNil(block.link(at: CGPoint(x: 1, y: rect.midY)))
    }

    // MARK: - Pointing at nothing
    //
    // `characterIndex(at:)` is the half of the split that may decline, and the
    // contract that keeps a click to the right of a link from opening it. Its
    // counterpart `index(at:)` clamps, so asserting the two against the same point
    // is what shows they are answering different questions rather than one being a
    // convenience over the other.

    func testPointingBesideTheTextIsPointingAtNothing() throws {
        let block = measured("[word](https://example.com)")
        let rect = try XCTUnwrap(block.fullRects().first)
        let beside = CGPoint(x: rect.maxX + 60, y: rect.midY)

        XCTAssertNil(block.characterIndex(at: beside))
        // The same point still has to resolve for a caret — a drag that ends out
        // here selects to the end of the line rather than selecting nothing.
        XCTAssertGreaterThan(block.index(at: beside), 0)
    }

    func testPointingBelowTheTextIsPointingAtNothing() throws {
        let block = measured("[word](https://example.com)")
        let rect = try XCTUnwrap(block.fullRects().first)
        XCTAssertNil(block.characterIndex(at: CGPoint(x: rect.midX, y: rect.maxY + 40)))
    }

    // MARK: - What a link carries

    /// The destination and where it sits — no title. A markdown title —
    /// `[a](b "title")` — is parsed and dropped: what to *show* for a link is the
    /// host's, reached through the delegate, and a second string riding along here
    /// would be this package deciding for it. The range is not a third thing of
    /// that kind; it is the location of the thing that was found, which a query
    /// that locates something owes its caller.
    func testALinkCarriesItsDestinationAlone() throws {
        let titled = measured(#"[word](https://example.com "Read this")"#)
        let plain = measured("[word](https://example.com)")
        XCTAssertEqual(
            try titled.link(at: onTheLink(titled))?.url.absoluteString, "https://example.com")
        XCTAssertEqual(
            try plain.link(at: onTheLink(plain))?.url.absoluteString, "https://example.com")
    }

    /// An image is a reference to a file, and it reports one the same way a link
    /// reports a page — which is what makes its standing-in glyph identifiable.
    func testAnImageCarriesItsSource() throws {
        let block = measured("![a diagram](assets/block-tree.png)")
        XCTAssertEqual(
            try block.link(at: onTheLink(block))?.url.absoluteString, "assets/block-tree.png")
    }

    // MARK: - Press, drag, release

    private struct Mounted {
        let window: NSWindow
        let cell: BlockView
        let block: MeasuredBlock
        var activated: [URL] { recorder.urls }
        var hovers: [URL?] { recorder.hovers }
        let recorder: Recorder
    }

    private final class Recorder {
        var urls: [URL] = []
        var hovers: [URL?] = []
    }

    private func mount(_ source: String, width: CGFloat = 400) -> Mounted {
        NSApplication.shared.setActivationPolicy(.prohibited)

        let block = MarkdownBlockBuilder.make(source).measure(width)
        let size = CGSize(width: width, height: block.size.height)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.alphaValue = 0.01
        // `close()` below would otherwise release it while this test still holds
        // one — `NSWindow` defaults this to `true`, which predates ARC and means
        // an over-release that surfaces as a segfault inside some later test's
        // runloop turn rather than here.
        window.isReleasedWhenClosed = false

        let cell = BlockView()
        cell.frame = NSRect(origin: .zero, size: size)
        window.contentView?.addSubview(cell)
        cell.configure(with: block)
        window.orderFront(nil)

        let recorder = Recorder()
        cell.onLinkActivated = { _, url in recorder.urls.append(url) }
        cell.onLinkHovered = { _, url, _ in recorder.hovers.append(url) }

        return Mounted(window: window, cell: cell, block: block, recorder: recorder)
    }

    private func event(
        _ mounted: Mounted, at point: CGPoint, _ type: NSEvent.EventType, clicks: Int = 1
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: mounted.cell.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: mounted.window.windowNumber, context: nil,
            eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    func testClickOnALinkActivatesIt() throws {
        let mounted = mount("[word](https://example.com)")
        let point = try onTheLink(mounted.block)

        mounted.cell.mouseDown(with: event(mounted, at: point, .leftMouseDown))
        mounted.cell.mouseUp(with: event(mounted, at: point, .leftMouseUp))

        XCTAssertEqual(mounted.activated.map(\.absoluteString), ["https://example.com"])
        mounted.window.close()
    }

    func testClickBesideALinkActivatesNothing() throws {
        let mounted = mount("[word](https://example.com)")
        let rect = try XCTUnwrap(mounted.block.fullRects().first)
        let point = CGPoint(x: rect.maxX + 60, y: rect.midY)

        mounted.cell.mouseDown(with: event(mounted, at: point, .leftMouseDown))
        mounted.cell.mouseUp(with: event(mounted, at: point, .leftMouseUp))

        XCTAssertTrue(mounted.activated.isEmpty)
        mounted.window.close()
    }

    /// A link's text stays selectable. The press starts on the link, the drag
    /// takes a range, and the release opens nothing.
    func testDraggingFromALinkSelectsInsteadOfActivating() throws {
        let mounted = mount("[a long enough link to drag across](https://example.com)")
        let rect = try XCTUnwrap(mounted.block.fullRects().first)
        let from = CGPoint(x: rect.minX + 4, y: rect.midY)
        let to = CGPoint(x: rect.midX, y: rect.midY)

        mounted.cell.mouseDown(with: event(mounted, at: from, .leftMouseDown))
        mounted.cell.mouseDragged(with: event(mounted, at: to, .leftMouseDragged))
        mounted.cell.mouseUp(with: event(mounted, at: to, .leftMouseUp))

        XCTAssertTrue(mounted.activated.isEmpty)
        mounted.window.close()
    }

    /// Double-clicking a word inside a link takes the word, the way it does
    /// anywhere else — the second click must not also open it.
    func testDoubleClickTakesTheWordInsteadOfActivating() throws {
        let mounted = mount("[word](https://example.com)")
        let point = try onTheLink(mounted.block)

        mounted.cell.mouseDown(with: event(mounted, at: point, .leftMouseDown, clicks: 2))
        mounted.cell.mouseUp(with: event(mounted, at: point, .leftMouseUp, clicks: 2))

        XCTAssertTrue(mounted.activated.isEmpty)
        mounted.window.close()
    }

    /// `mouseEvent(with:…)` rejects the enter/exit types — AppKit builds those
    /// through a different factory, and they carry a tracking number rather than
    /// a click count.
    private func exitEvent(_ mounted: Mounted) -> NSEvent {
        NSEvent.enterExitEvent(
            with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: mounted.window.windowNumber, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil)!
    }

    // MARK: - What a hover reports
    //
    // The package draws nothing for a hover; it says which link the pointer is
    // on and stops there. So what there is to hold is the *report* — that it
    // arrives, that it says `nil` on the way out, and that it is one call per
    // link rather than one per mouse-moved event, which is the contract a host
    // relies on to avoid keeping state of its own.

    func testMovingOntoALinkReportsIt() throws {
        let mounted = mount("[word](https://example.com)")
        defer { mounted.window.close() }
        let rect = try XCTUnwrap(mounted.block.fullRects().first)

        mounted.cell.mouseMoved(
            with: event(mounted, at: CGPoint(x: rect.midX, y: rect.midY), .mouseMoved))
        XCTAssertEqual(mounted.hovers.map { $0?.absoluteString }, ["https://example.com"])

        mounted.cell.mouseMoved(
            with: event(mounted, at: CGPoint(x: rect.maxX + 60, y: rect.midY), .mouseMoved))
        XCTAssertEqual(mounted.hovers.map { $0?.absoluteString }, ["https://example.com", nil])
    }

    /// The contract that lets a host treat every call as an instruction: sliding
    /// along one link is one report, not one per pixel.
    func testSlidingAlongOneLinkReportsOnce() throws {
        let mounted = mount("[a long enough link to slide along](https://example.com)")
        defer { mounted.window.close() }
        let rect = try XCTUnwrap(mounted.block.fullRects().first)

        for offset in stride(from: rect.minX + 4, to: rect.maxX - 4, by: 3) {
            mounted.cell.mouseMoved(
                with: event(mounted, at: CGPoint(x: offset, y: rect.midY), .mouseMoved))
        }
        XCTAssertEqual(mounted.hovers.count, 1)
    }

    /// Leaving through an edge produces no further move inside the view, so the
    /// exit is what takes the report back.
    func testLeavingTheRowReportsNothingUnderThePointer() throws {
        let mounted = mount("[word](https://example.com)")
        defer { mounted.window.close() }
        let rect = try XCTUnwrap(mounted.block.fullRects().first)

        mounted.cell.mouseMoved(
            with: event(mounted, at: CGPoint(x: rect.midX, y: rect.midY), .mouseMoved))
        mounted.cell.mouseExited(with: exitEvent(mounted))
        XCTAssertEqual(mounted.hovers.map { $0?.absoluteString }, ["https://example.com", nil])
    }

    /// Prose is not a link, and "still nothing" is not a change worth a call.
    func testProseReportsNothingAtAll() throws {
        let mounted = mount("just words with no link in them at all")
        defer { mounted.window.close() }
        let rect = try XCTUnwrap(mounted.block.fullRects().first)

        mounted.cell.mouseMoved(
            with: event(mounted, at: CGPoint(x: rect.midX, y: rect.midY), .mouseMoved))
        XCTAssertTrue(mounted.hovers.isEmpty)
    }

}
