import AppKit
import XCTest

@testable import TranscriptKit

/// The right-click menu: what the transcript puts in it, what it does to the
/// selection on the way, and how a host's items get in beside its own.
///
/// Two halves, mounted differently on purpose. The first drives `BlockView`
/// directly, because everything it asserts is one row's business and a table
/// around it would only be scenery. The second mounts a real transcript, because
/// the only thing left to check there is the *wiring* — that the host is asked
/// about the row it clicked, and that its answer is what gets shown.
///
/// `menu(for:)` is an ordinary method, so both halves are reachable without a
/// pointer — the same reason `mouseMoved` is testable while a real hover is not.
@MainActor
final class ContextMenuTests: XCTestCase {

    // MARK: - Harness

    private struct Mounted {
        let window: NSWindow
        let cell: BlockView
        let block: MeasuredBlock
    }

    private func mount(_ source: String, width: CGFloat = 400) -> Mounted {
        NSApplication.shared.setActivationPolicy(.prohibited)

        let block = MarkdownBlockBuilder.make(source).measure(width)
        let size = CGSize(width: width, height: block.size.height)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.alphaValue = 0.01
        window.isReleasedWhenClosed = false

        let cell = BlockView()
        cell.frame = NSRect(origin: .zero, size: size)
        window.contentView?.addSubview(cell)
        cell.configure(with: block)
        window.orderFront(nil)

        return Mounted(window: window, cell: cell, block: block)
    }

    private func rightClick(_ mounted: Mounted, at point: CGPoint) -> NSMenu? {
        mounted.cell.menu(
            for: NSEvent.mouseEvent(
                with: .rightMouseDown, location: mounted.cell.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: mounted.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
    }

    private func drag(_ mounted: Mounted, from: CGPoint, to: CGPoint) {
        for (point, type) in [(from, NSEvent.EventType.leftMouseDown), (to, .leftMouseDragged)] {
            mounted.cell.mouseDown(with: point, type, in: mounted.window)
        }
    }

    private func copiedText(_ mounted: Mounted) -> String? {
        NSPasteboard.general.clearContents()
        mounted.cell.copy(nil)
        return NSPasteboard.general.string(forType: .string)
    }

    /// The x of each of three equal words on one line, so a test can point at
    /// "the first word" without knowing where a glyph landed.
    private func word(_ nth: Int, in mounted: Mounted) throws -> CGPoint {
        let line = try XCTUnwrap(mounted.block.fullRects().first)
        return CGPoint(x: line.minX + line.width * (CGFloat(nth) * 2 + 1) / 6, y: line.midY)
    }

    // MARK: - What the transcript puts in it

    func testTheMenuCarriesCopy() throws {
        let mounted = mount("alpha beta gamma")
        defer { mounted.window.close() }

        let menu = try XCTUnwrap(rightClick(mounted, at: try word(1, in: mounted)))
        let copy = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(copy.action, #selector(BlockView.copy(_:)))
        // A `nil` target is not a detail — it is the whole dispatch mechanism.
        // Pointed at the view directly, the item would bypass the responder
        // chain and `validateMenuItem` with it.
        XCTAssertNil(copy.target)
    }

    /// Stands in for whatever else in a window can hold focus — an input bar,
    /// another row. A window with only the cell in it makes the cell its initial
    /// first responder on `orderFront`, which would let the test below pass
    /// without the production code doing anything.
    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// A menu item with a `nil` target resolves against the *window's* first
    /// responder, so right-clicking a row nobody has clicked has to move focus
    /// first — otherwise Copy validates against whatever still held it.
    func testRightClickTakesTheFirstResponder() throws {
        let mounted = mount("alpha beta gamma")
        defer { mounted.window.close() }

        let elsewhere = FocusableView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        mounted.window.contentView?.addSubview(elsewhere)
        mounted.window.makeFirstResponder(elsewhere)
        XCTAssertTrue(mounted.window.firstResponder === elsewhere, "focus never left the cell")

        _ = rightClick(mounted, at: try word(1, in: mounted))
        XCTAssertTrue(mounted.window.firstResponder === mounted.cell)
    }

    // MARK: - What it does to the selection

    /// Without this, right-clicking prose would show a menu whose only item is
    /// greyed out. `NSTextView` and WebKit both take the word instead.
    func testRightClickWithNothingSelectedTakesTheWordUnderIt() throws {
        let mounted = mount("alpha beta gamma")
        defer { mounted.window.close() }

        _ = rightClick(mounted, at: try word(1, in: mounted))
        XCTAssertEqual(copiedText(mounted), "beta")
    }

    /// The click landed on what the reader had already selected, so that is what
    /// they are pointing at — narrowing it to one word would be the surprise.
    func testRightClickInsideASelectionKeepsIt() throws {
        let mounted = mount("alpha beta gamma")
        defer { mounted.window.close() }

        let line = try XCTUnwrap(mounted.block.fullRects().first)
        drag(mounted, from: CGPoint(x: -500, y: line.midY), to: CGPoint(x: 5_000, y: line.midY))
        XCTAssertEqual(copiedText(mounted), "alpha beta gamma")

        _ = rightClick(mounted, at: try word(1, in: mounted))
        XCTAssertEqual(copiedText(mounted), "alpha beta gamma")
    }

    func testRightClickOutsideASelectionMovesToTheWordUnderIt() throws {
        let mounted = mount("alpha beta gamma")
        defer { mounted.window.close() }

        // Double-click takes "alpha"; the right-click then lands two words away.
        mounted.cell.mouseDown(with: try word(0, in: mounted), .leftMouseDown, in: mounted.window, clicks: 2)
        XCTAssertEqual(copiedText(mounted), "alpha")

        _ = rightClick(mounted, at: try word(2, in: mounted))
        XCTAssertEqual(copiedText(mounted), "gamma")
    }

    // MARK: - How the host gets in

    func testWithNoHostWiredTheTranscriptsOwnMenuShows() throws {
        let mounted = mount("alpha beta gamma")
        defer { mounted.window.close() }

        let menu = try XCTUnwrap(rightClick(mounted, at: try word(1, in: mounted)))
        XCTAssertEqual(menu.items.count, 1)
    }

    /// The proposal arrives with the transcript's own items already on it, and
    /// what comes back is what shows — which is what lets the two sets compose
    /// rather than one replacing the other.
    func testTheHostsAnswerIsWhatShows() throws {
        let mounted = mount("alpha beta gamma")
        defer { mounted.window.close() }

        var proposed: [String] = []
        mounted.cell.onContextMenu = { _, menu in
            proposed = menu.items.map(\.title)
            menu.addItem(NSMenuItem(title: "Quote", action: nil, keyEquivalent: ""))
            return menu
        }

        let menu = try XCTUnwrap(rightClick(mounted, at: try word(1, in: mounted)))
        XCTAssertEqual(proposed.count, 1, "the host was handed a menu without the transcript's own items on it")
        XCTAssertEqual(menu.items.map(\.title).last, "Quote")
    }

    func testTheHostCanSuppressTheMenuEntirely() throws {
        let mounted = mount("alpha beta gamma")
        defer { mounted.window.close() }

        mounted.cell.onContextMenu = { _, _ in nil }
        XCTAssertNil(rightClick(mounted, at: try word(1, in: mounted)))
    }

    // MARK: - The transcript's wiring

    /// A data source of markdown rows, recording what the menu hook was asked.
    private final class MarkdownHost: NSObject, TranscriptViewDataSource, TranscriptViewDelegate {
        let rows: [String]
        var askedForRows: [Int] = []
        var answer: (NSMenu) -> NSMenu?

        init(rows: [String], answer: @escaping (NSMenu) -> NSMenu? = { $0 }) {
            self.rows = rows
            self.answer = answer
        }

        func numberOfRows(in transcriptView: TranscriptView) -> Int { rows.count }

        func transcriptView(
            _ transcriptView: TranscriptView, contentForRow row: Int
        ) -> TranscriptRowContent {
            .markdown(rows[row])
        }

        func transcriptView(
            _ transcriptView: TranscriptView, menu: NSMenu, forRow row: Int
        ) -> NSMenu? {
            askedForRows.append(row)
            return answer(menu)
        }
    }

    private func mountTranscript(_ host: MarkdownHost) -> MountedTranscript {
        let mounted = MountedTranscript(size: NSSize(width: 400, height: 600))
        mounted.transcript.dataSource = host
        mounted.transcript.delegate = host
        mounted.settle()
        mounted.transcript.reloadData()
        mounted.settle()
        return mounted
    }

    func testTheDelegateIsAskedAboutTheRowThatWasClicked() throws {
        let host = MarkdownHost(rows: ["alpha", "beta", "gamma", "delta"])
        let mounted = mountTranscript(host)
        defer { mounted.teardown() }

        let cells = mounted.transcript.descendants(ofType: BlockView.self)
        XCTAssertFalse(cells.isEmpty, "the transcript built no self-drawn rows, so nothing below is tested")

        // The last one on screen, so a wiring that always reported row 0 — or the
        // index captured when the view was built rather than the current one —
        // would show up.
        let cell = try XCTUnwrap(cells.last)
        let row = mounted.transcript.row(for: cell)
        XCTAssertGreaterThan(row, 0)

        _ = cell.menu(
            for: NSEvent.mouseEvent(
                with: .rightMouseDown, location: cell.convert(CGPoint(x: 4, y: 4), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: mounted.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)

        XCTAssertEqual(host.askedForRows, [row])
    }

    /// The guard against a quiet flattening bug: optional-chaining a delegate
    /// method that itself returns an optional collapses "no delegate" and "the
    /// delegate said no menu" into one `nil`, and a `?? menu` fallback then hands
    /// back the default menu for both. A host suppressing the menu would silently
    /// get one.
    func testADelegateReturningNilShowsNoMenu() throws {
        let host = MarkdownHost(rows: ["alpha", "beta"], answer: { _ in nil })
        let mounted = mountTranscript(host)
        defer { mounted.teardown() }

        let cell = try XCTUnwrap(mounted.transcript.descendants(ofType: BlockView.self).first)
        let menu = cell.menu(
            for: NSEvent.mouseEvent(
                with: .rightMouseDown, location: cell.convert(CGPoint(x: 4, y: 4), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: mounted.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)

        XCTAssertEqual(host.askedForRows.count, 1, "the delegate was never asked, so the nil proves nothing")
        XCTAssertNil(menu)
    }
}

extension BlockView {

    /// A mouse event at a point in this view's own (flipped) coordinates.
    fileprivate func mouseDown(
        with point: CGPoint, _ type: NSEvent.EventType, in window: NSWindow, clicks: Int = 1
    ) {
        let event = NSEvent.mouseEvent(
            with: type, location: convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
            pressure: 1)!
        switch type {
        case .leftMouseDragged: mouseDragged(with: event)
        default: mouseDown(with: event)
        }
    }
}
