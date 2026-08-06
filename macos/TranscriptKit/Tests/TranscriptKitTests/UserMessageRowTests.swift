import AppKit
import XCTest

@testable import TranscriptKit

/// `.userMessage` rows end to end: the transcript measures them itself, serves
/// them through its own cell, and re-measures them when the column moves.
///
/// Mounted rather than pure, unlike `UserMessageTests` — the bubble's geometry is
/// a value, but *whether the transcript reaches for one* is only observable once
/// `NSTableView` lays out and starts asking.
@MainActor
final class UserMessageRowTests: XCTestCase {

    private var mounted: MountedTranscript!

    /// Held by the test, because the transcript holds its data source and
    /// delegate weakly.
    private var host: UserMessageHost!

    override func tearDown() {
        mounted?.teardown()
        mounted = nil
        host = nil
        super.tearDown()
    }

    @discardableResult
    private func mount(_ messages: [String], width: CGFloat = 600) -> UserMessageHost {
        let host = UserMessageHost(messages: messages)
        self.host = host
        mounted = MountedTranscript(size: NSSize(width: width, height: 400))
        mounted.transcript.dataSource = host
        mounted.transcript.delegate = host
        mounted.settle()
        mounted.transcript.reloadData()
        mounted.settle()
        return host
    }

    // MARK: - Measured by the transcript, not the delegate

    func testUserMessagesAreMeasuredWithoutAskingTheDelegate() {
        let host = mount(["Hi.", "A second message."])

        XCTAssertEqual(mounted.transcript.numberOfRows, 2)
        // The provocation check: a mount that never laid out would leave every
        // row at zero and make the rest of this pass vacuously.
        XCTAssertGreaterThan(mounted.transcript.rect(ofRow: 0).height, 0)
        XCTAssertGreaterThan(mounted.transcript.rect(ofRow: 1).height, 0)

        // `heightOfRow` is the `.view` path. A user message must not touch it.
        XCTAssertTrue(host.heightWidths.isEmpty)
        XCTAssertEqual(host.viewCalls, 0)
    }

    func testUserMessageIsServedThroughTheTranscriptsOwnCell() {
        mount(["Hi."])
        XCTAssertEqual(mounted.transcript.descendants(ofType: BlockView.self).count, 1)
    }

    /// A wrapping message is taller than one that fits on a line — the cheapest
    /// proof the row was measured from a typeset tree rather than from a constant.
    func testAWrappingMessageIsTallerThanAShortOne() {
        mount(["Hi.", String(repeating: "word ", count: 60)])
        XCTAssertGreaterThan(
            mounted.transcript.rect(ofRow: 1).height, mounted.transcript.rect(ofRow: 0).height)
    }

    // MARK: - Re-measured on a width change

    /// The half of a reflow that nothing else is watching.
    ///
    /// A width change invalidates every row's *height* through `noteHeightOfRows`,
    /// so a row's rectangle comes out right whether or not the view inside it was
    /// re-measured. What goes wrong when it wasn't is that the cell keeps the tree
    /// it was configured with — and with `layerContentsRedrawPolicy` at `.never`,
    /// the old bitmap is stretched to the new size rather than redrawn. Asserting
    /// on the row's height cannot see that; asserting on the block the view is
    /// holding can.
    func testNarrowingRemeasuresTheBubbleTheCellIsShowing() throws {
        mount([String(repeating: "word ", count: 60)], width: 700)

        let view = try XCTUnwrap(mounted.transcript.descendants(ofType: BlockView.self).first)
        XCTAssertEqual(try XCTUnwrap(view.block).size.width, 700, accuracy: 1)
        let wide = mounted.transcript.rect(ofRow: 0).height

        mounted.setContentWidth(320)
        mounted.settle()

        XCTAssertEqual(try XCTUnwrap(view.block).size.width, 320, accuracy: 1)
        XCTAssertGreaterThan(mounted.transcript.rect(ofRow: 0).height, wide)
    }

    // MARK: - The More affordance, in a mounted row
    //
    // The value-level half — that it is a link, where its rectangle is, what it
    // copies as — is `UserMessageTests`. What needs a view is the part `BlockView`
    // owns: that hovering it draws the same band a link gets, and that pressing it
    // does not reach the host as a link would.

    private static func longMessage(lines: Int = 40) -> String {
        (1...lines).map { "line \($0) of a message long enough to be cut short" }
            .joined(separator: "\n")
    }

    private func hoverTheMoreRun() throws -> (view: BlockView, more: CGRect) {
        let view = try XCTUnwrap(mounted.transcript.descendants(ofType: BlockView.self).first)
        let block = try XCTUnwrap(view.block as? UserMessage.Measured)
        let more = try XCTUnwrap(block.more).frame

        let point = CGPoint(x: more.midX, y: more.midY)
        view.mouseMoved(with: try event(view, at: point, .mouseMoved))
        return (view, more)
    }

    private func event(
        _ view: BlockView, at point: CGPoint, _ type: NSEvent.EventType
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: mounted.window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
    }

    /// The band is `BlockView`'s, drawn for any activatable run — so what this
    /// asserts is that the affordance *is* one, all the way through: the point
    /// resolved to a link, the band's path is the run's own rectangle, and the
    /// paint order was cut so the band lands over the bubble's fill and under the
    /// glyphs.
    func testHoveringTheMoreRunDrawsABandOverTheBubbleAndUnderTheGlyphs() throws {
        mount([Self.longMessage()])
        let (view, more) = try hoverTheMoreRun()

        let sublayers = try XCTUnwrap(view.layer?.sublayers)
        XCTAssertEqual(sublayers.count, 3, "expected the fill, the band, then the glyphs")
        XCTAssertFalse(sublayers[0] is CAShapeLayer)
        let band = try XCTUnwrap(sublayers[1] as? CAShapeLayer, "the band is not between them")
        XCTAssertFalse(sublayers[2] is CAShapeLayer)

        // The run's own rectangle, grown by the band's inset on every side — so
        // the tint reaches past the first and last stem rather than being clipped
        // by them.
        let box = try XCTUnwrap(band.path?.boundingBox)
        XCTAssertEqual(box.minX, more.minX - 2, accuracy: 0.5)
        XCTAssertEqual(box.minY, more.minY - 2, accuracy: 0.5)
        XCTAssertEqual(box.width, more.width + 4, accuracy: 0.5)
        XCTAssertEqual(box.height, more.height + 4, accuracy: 0.5)
    }

    /// The press feedback: the band is already there from the hover, and the
    /// button going down deepens it. Asserted as a *change* rather than against a
    /// constant — what matters is that a press is distinguishable from a hover,
    /// not which two alphas were picked.
    func testPressingTheMoreRunDeepensTheBand() throws {
        mount([Self.longMessage()])
        let (view, more) = try hoverTheMoreRun()
        let band = try XCTUnwrap(
            (view.layer?.sublayers ?? []).compactMap { $0 as? CAShapeLayer }.first)
        let hovering = try XCTUnwrap(band.fillColor?.alpha)

        let point = CGPoint(x: more.midX, y: more.midY)
        view.mouseDown(with: try event(view, at: point, .leftMouseDown))
        let pressing = try XCTUnwrap(band.fillColor?.alpha)
        XCTAssertGreaterThan(pressing, hovering)

        // And back, because the pointer is still on the run — it was the press
        // that ended, not the hover.
        view.mouseUp(with: try event(view, at: point, .leftMouseUp))
        XCTAssertEqual(try XCTUnwrap(band.fillColor?.alpha), hovering, accuracy: 0.001)
    }

    /// A press that turns into a drag stops being a press: the same rule that
    /// keeps it from activating the run should stop it looking activated.
    func testDraggingOffAPressReturnsTheBandToItsHoverTint() throws {
        mount([Self.longMessage()])
        let (view, more) = try hoverTheMoreRun()
        let band = try XCTUnwrap(
            (view.layer?.sublayers ?? []).compactMap { $0 as? CAShapeLayer }.first)
        let hovering = try XCTUnwrap(band.fillColor?.alpha)

        view.mouseDown(
            with: try event(view, at: CGPoint(x: more.midX, y: more.midY), .leftMouseDown))
        XCTAssertGreaterThan(try XCTUnwrap(band.fillColor?.alpha), hovering)

        // Far enough to select something, which is what makes it a drag.
        view.mouseDragged(
            with: try event(view, at: CGPoint(x: more.minX - 80, y: more.midY - 30), .leftMouseDragged))
        XCTAssertEqual(try XCTUnwrap(band.fillColor?.alpha), hovering, accuracy: 0.001)
    }

    func testMovingOffTheMoreRunTakesTheBandAway() throws {
        mount([Self.longMessage()])
        let (view, more) = try hoverTheMoreRun()
        XCTAssertNotNil((view.layer?.sublayers ?? []).first { $0 is CAShapeLayer })

        // Onto the message above it, which is not a link.
        view.mouseMoved(
            with: try event(view, at: CGPoint(x: more.midX, y: more.minY - 40), .mouseMoved))
        mounted.settle()

        // The band fades before it goes, so what is asserted is that it is on its
        // way out rather than that it has gone.
        let band = (view.layer?.sublayers ?? []).compactMap { $0 as? CAShapeLayer }.first
        XCTAssertEqual(band?.opacity ?? 0, 0, accuracy: 0.01)
    }

    /// Pressing it reaches nobody — there is no delegate requirement for it yet,
    /// and it must not be mistaken for a link on the way out. The affordance is
    /// drawn and hovers; what a press *does* lands with the first host that has
    /// somewhere to put the rest of the message.
    func testPressingTheMoreRunActivatesNoLink() throws {
        let host = mount([Self.longMessage()])
        let (view, more) = try hoverTheMoreRun()

        let point = CGPoint(x: more.midX, y: more.midY)
        view.mouseDown(with: try event(view, at: point, .leftMouseDown))
        view.mouseUp(with: try event(view, at: point, .leftMouseUp))

        XCTAssertTrue(host.activated.isEmpty)
    }

    // MARK: - Sharing the pool

    /// All three row kinds on screen at once. They share one recycling pool, so a
    /// cell handed back from the wrong kind of row is a real failure mode — and
    /// one a single-kind fixture cannot see.
    func testUserMessageMarkdownAndHostRowsCoexist() {
        let host = mount(
            ["Hi.", UserMessageHost.markdownMarker, UserMessageHost.hostRowMarker, "And again."])

        // Three self-drawn rows: two user messages and the markdown one.
        XCTAssertEqual(mounted.transcript.descendants(ofType: BlockView.self).count, 3)
        XCTAssertEqual(mounted.transcript.descendants(ofType: RecordingHost.ProbeView.self).count, 1)
        // Asked about the host's row, and only that one.
        XCTAssertEqual(host.heightWidths.count, 1)
    }
}

/// Answers `.userMessage` for every row but the two carrying a marker — one
/// `.markdown`, one `.view` — so one fixture covers all three row kinds.
@MainActor
private final class UserMessageHost: NSObject, TranscriptViewDataSource, TranscriptViewDelegate {

    static let hostRowMarker = "\u{0}host-drawn"
    static let markdownMarker = "\u{0}markdown"

    private let messages: [String]
    private let ids: [UUID]

    private(set) var heightWidths: [CGFloat] = []
    private(set) var viewCalls = 0
    private(set) var activated: [URL] = []

    init(messages: [String]) {
        self.messages = messages
        ids = messages.map { _ in UUID() }
        super.init()
    }

    func numberOfRows(in transcriptView: TranscriptView) -> Int { messages.count }

    func transcriptView(_ transcriptView: TranscriptView, rowAt row: Int) -> TranscriptRow {
        let content: TranscriptRowContent
        switch messages[row] {
        case Self.hostRowMarker: content = .view
        case Self.markdownMarker: content = .markdown("# A document")
        default: content = .userMessage(messages[row])
        }
        return TranscriptRow(id: ids[row], content: content)
    }

    func transcriptView(
        _ transcriptView: TranscriptView, heightOfRow row: Int, width: CGFloat
    ) -> CGFloat {
        heightWidths.append(width)
        return 40
    }

    func transcriptView(_ transcriptView: TranscriptView, viewForRow row: Int) -> NSView {
        viewCalls += 1
        return transcriptView.makeView(withIdentifier: Self.probe) { RecordingHost.ProbeView() }
    }

    func transcriptView(
        _ transcriptView: TranscriptView, didActivate url: URL, inRow row: Int
    ) {
        activated.append(url)
    }

    private static let probe = NSUserInterfaceItemIdentifier("UserMessageRowTests.probe")
}
