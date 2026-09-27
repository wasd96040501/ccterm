import AppKit
import XCTest

@testable import TranscriptKit

/// The right-click menu: what the transcript puts in it, what it does to the
/// selection on the way, and how a host's items get in beside its own.
///
/// Mounted in a real transcript throughout: the selection a right-click acts on is
/// the transcript's, and so is the responder Copy is validated against. The
/// host's half is checked twice — once on a row's view directly, where the only
/// question is how its proposal composes with an answer, and once through the
/// delegate, where the question is the *wiring*: that the host is asked about the
/// row it clicked, and that its answer is what gets shown.
///
/// `menu(for:)` is an ordinary method, so everything here is reachable without a
/// pointer — the same reason `mouseMoved` is testable while a real hover is not.
@MainActor
final class ContextMenuTests: XCTestCase {

    // MARK: - Harness

    private struct Mounted {
        let transcript: MountedTranscript
        let host: MarkdownHost
        let cell: BlockView
        let block: MeasuredBlock
        var window: NSWindow { transcript.window }
    }

    private func mount(_ source: String) throws -> Mounted {
        let host = MarkdownHost(rows: [source])
        let transcript = mountTranscript(host)
        let cell = try XCTUnwrap(transcript.transcript.descendants(ofType: BlockView.self).first)
        return Mounted(transcript: transcript, host: host, cell: cell, block: try XCTUnwrap(cell.block))
    }

    private func rightClick(_ mounted: Mounted, at point: CGPoint) -> NSMenu? {
        mounted.cell.menu(
            for: NSEvent.mouseEvent(
                with: .rightMouseDown, location: mounted.cell.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: mounted.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
    }

    private func drag(_ mounted: Mounted, from: CGPoint, to: CGPoint) {
        mounted.transcript.press(
            mounted.cell, with: mounted.cell.event(.leftMouseDown, at: from),
            then: [mounted.cell.event(.leftMouseDragged, at: to)])
    }

    /// The x of each of three equal words on one line, so a test can point at
    /// "the first word" without knowing where a glyph landed.
    private func word(_ nth: Int, in mounted: Mounted) throws -> CGPoint {
        let line = try XCTUnwrap(mounted.block.fullRects().first)
        return CGPoint(x: line.minX + line.width * (CGFloat(nth) * 2 + 1) / 6, y: line.midY)
    }

    // MARK: - What the transcript puts in it

    func testTheMenuCarriesCopy() throws {
        let mounted = try mount("alpha beta gamma")
        defer { mounted.transcript.teardown() }

        let menu = try XCTUnwrap(rightClick(mounted, at: try word(1, in: mounted)))
        let copy = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(copy.action, #selector(NSText.copy(_:)))
        // A `nil` target is not a detail — it is the whole dispatch mechanism.
        // Pointed at a view directly, the item would bypass the responder chain
        // and validation with it.
        XCTAssertNil(copy.target)
    }

    /// Stands in for whatever else in a window can hold focus — an input bar,
    /// another transcript.
    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// A menu item with a `nil` target resolves against the *window's* first
    /// responder, so right-clicking a row nobody has clicked has to move focus
    /// first — otherwise Copy validates against whatever still held it.
    func testRightClickTakesTheFirstResponder() throws {
        let mounted = try mount("alpha beta gamma")
        defer { mounted.transcript.teardown() }

        let elsewhere = FocusableView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        mounted.window.contentView?.addSubview(elsewhere)
        mounted.window.makeFirstResponder(elsewhere)
        XCTAssertTrue(mounted.window.firstResponder === elsewhere, "focus never left the transcript")

        _ = rightClick(mounted, at: try word(1, in: mounted))
        XCTAssertTrue(mounted.transcript.canCopy, "Copy is not validated against the selection")
    }

    // MARK: - What it does to the selection

    /// Without this, right-clicking prose would show a menu whose only item is
    /// greyed out. `NSTextView` and WebKit both take the word instead.
    func testRightClickWithNothingSelectedTakesTheWordUnderIt() throws {
        let mounted = try mount("alpha beta gamma")
        defer { mounted.transcript.teardown() }

        _ = rightClick(mounted, at: try word(1, in: mounted))
        XCTAssertEqual(mounted.transcript.copy(), "beta")
    }

    /// The click landed on what the reader had already selected, so that is what
    /// they are pointing at — narrowing it to one word would be the surprise.
    func testRightClickInsideASelectionKeepsIt() throws {
        let mounted = try mount("alpha beta gamma")
        defer { mounted.transcript.teardown() }

        let line = try XCTUnwrap(mounted.block.fullRects().first)
        drag(mounted, from: CGPoint(x: -500, y: line.midY), to: CGPoint(x: 5_000, y: line.midY))
        XCTAssertEqual(mounted.transcript.copy(), "alpha beta gamma")

        _ = rightClick(mounted, at: try word(1, in: mounted))
        XCTAssertEqual(mounted.transcript.copy(), "alpha beta gamma")
    }

    /// And inside a selection that runs across rows, whichever row the click is in.
    func testRightClickInsideASelectionAcrossRowsKeepsIt() throws {
        let host = MarkdownHost(rows: ["alpha one", "beta two", "gamma three"])
        let mounted = mountTranscript(host)
        defer { mounted.teardown() }
        let cells = mounted.transcript.descendants(ofType: BlockView.self)
            .sorted { mounted.transcript.row(for: $0) < mounted.transcript.row(for: $1) }
        XCTAssertEqual(cells.count, 3)

        mounted.press(
            cells[0], with: cells[0].event(.leftMouseDown, at: CGPoint(x: -500, y: 4)),
            then: [cells[2].event(.leftMouseDragged, at: CGPoint(x: 5_000, y: 4))])
        let selected = mounted.copy()
        XCTAssertEqual(selected, "alpha one\n\nbeta two\n\ngamma three")

        _ = cells[1].menu(
            for: NSEvent.mouseEvent(
                with: .rightMouseDown, location: cells[1].convert(CGPoint(x: 4, y: 4), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: mounted.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        XCTAssertEqual(mounted.copy(), selected)
    }

    func testRightClickOutsideASelectionMovesToTheWordUnderIt() throws {
        let mounted = try mount("alpha beta gamma")
        defer { mounted.transcript.teardown() }

        // Double-click takes "alpha"; the right-click then lands two words away.
        mounted.transcript.press(
            mounted.cell, with: mounted.cell.event(.leftMouseDown, at: try word(0, in: mounted), clicks: 2))
        XCTAssertEqual(mounted.transcript.copy(), "alpha")

        _ = rightClick(mounted, at: try word(2, in: mounted))
        XCTAssertEqual(mounted.transcript.copy(), "gamma")
    }

    // MARK: - How the host gets in

    func testWithNoHostWiredTheTranscriptsOwnMenuShows() throws {
        let mounted = try mount("alpha beta gamma")
        defer { mounted.transcript.teardown() }

        let menu = try XCTUnwrap(rightClick(mounted, at: try word(1, in: mounted)))
        XCTAssertEqual(menu.items.count, 1)
    }

    /// The proposal arrives with the transcript's own items already on it, and
    /// what comes back is what shows — which is what lets the two sets compose
    /// rather than one replacing the other.
    func testTheHostsAnswerIsWhatShows() throws {
        let mounted = try mount("alpha beta gamma")
        defer { mounted.transcript.teardown() }

        var proposed: [String] = []
        mounted.cell.onContextMenu = { _, menu, _ in
            proposed = menu.items.map(\.title)
            menu.addItem(NSMenuItem(title: "Quote", action: nil, keyEquivalent: ""))
            return menu
        }

        let menu = try XCTUnwrap(rightClick(mounted, at: try word(1, in: mounted)))
        XCTAssertEqual(proposed.count, 1, "the host was handed a menu without the transcript's own items on it")
        XCTAssertEqual(menu.items.map(\.title).last, "Quote")
    }

    func testTheHostCanSuppressTheMenuEntirely() throws {
        let mounted = try mount("alpha beta gamma")
        defer { mounted.transcript.teardown() }

        mounted.cell.onContextMenu = { _, _, _ in nil }
        XCTAssertNil(rightClick(mounted, at: try word(1, in: mounted)))
    }

    // MARK: - The transcript's wiring

    /// A data source of markdown rows, recording what the menu hook was asked.
    private final class MarkdownHost: NSObject, TranscriptViewDataSource, TranscriptViewDelegate {
        let rows: [String]
        let ids: [UUID]
        var askedForRows: [Int] = []
        var answer: (NSMenu) -> NSMenu?

        init(rows: [String], answer: @escaping (NSMenu) -> NSMenu? = { $0 }) {
            self.rows = rows
            ids = rows.map { _ in UUID() }
            self.answer = answer
        }

        func numberOfRows(in transcriptView: TranscriptView) -> Int { rows.count }

        func transcriptView(_ transcriptView: TranscriptView, rowAt row: Int) -> TranscriptRow {
            TranscriptRow(id: ids[row], content: .markdown(rows[row]))
        }

        func transcriptView(
            _ transcriptView: TranscriptView, menu: NSMenu, forRow row: Int
        ) -> NSMenu? {
            askedForRows.append(row)
            return answer(menu)
        }
    }

    /// Hosts held here, because the transcript holds its data source weakly and
    /// the harness above hands back only the mount.
    private var hosts: [MarkdownHost] = []

    private func mountTranscript(_ host: MarkdownHost) -> MountedTranscript {
        hosts.append(host)
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
    fileprivate func event(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0,
            clickCount: clicks, pressure: 1)!
    }
}
