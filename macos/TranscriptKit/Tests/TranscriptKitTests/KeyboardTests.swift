import AppKit
import XCTest

@testable import TranscriptKit

/// What the transcript does with a key while it has focus: it scrolls on the
/// keys a reader scrolls with, and every other key reaches the view controller
/// above it as the event it was — which is what lets a host type into its input
/// while the transcript is focused.
///
/// Keys go through `NSWindow.sendEvent(_:)` to the first responder, the way the
/// window delivers them. The window is never key, which the delivery doesn't
/// need.
@MainActor
final class KeyboardTests: XCTestCase {

    /// The host's side: a view controller whose view holds the transcript, which
    /// puts it in the responder chain above the transcript the way any view
    /// controller is.
    private final class HostController: NSViewController {
        private(set) var keys: [NSEvent] = []

        override func keyDown(with event: NSEvent) {
            keys.append(event)
        }
    }

    private static let windowSize = NSSize(width: 1100, height: 720)

    private func mount(
        insets: NSEdgeInsets = NSEdgeInsets()
    ) -> (MountedTranscript, RecordingHost, HostController) {
        let mounted = MountedTranscript(size: Self.windowSize)
        let host = RecordingHost(rowCount: 100)
        mounted.transcript.dataSource = host
        mounted.transcript.delegate = host
        mounted.transcript.contentInsets = insets
        mounted.transcript.reloadData()
        mounted.settle()
        let controller = HostController()
        controller.view = mounted.window.contentView!
        let document = try! XCTUnwrap(mounted.scrollView.documentView)
        XCTAssertTrue(mounted.window.makeFirstResponder(document), "the transcript refused focus")
        return (mounted, host, controller)
    }

    private func press(
        _ mounted: MountedTranscript, _ characters: String, keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: mounted.window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
        mounted.window.sendEvent(event)
        mounted.settle()
        return event
    }

    private func offset(_ mounted: MountedTranscript) -> CGFloat {
        mounted.scrollView.documentVisibleRect.minY
    }

    // MARK: - Up the chain

    /// Typing, Return and Escape are the host's: each arrives at its view
    /// controller as the very event pressed, and the transcript doesn't move.
    func testKeysTheTranscriptDoesNotReadReachTheHostAsTheEvent() throws {
        let (mounted, _, controller) = mount()
        defer { mounted.teardown() }
        mounted.scroll(toY: 1000)
        mounted.settle()
        XCTAssertEqual(offset(mounted), 1000, "mount never placed rows")

        let pressed = [
            press(mounted, "a", keyCode: 0),
            press(mounted, " ", keyCode: 49),
            press(mounted, "\r", keyCode: 36),
            press(mounted, "\u{1b}", keyCode: 53),
        ]

        XCTAssertEqual(controller.keys, pressed)
        XCTAssertEqual(offset(mounted), 1000)
    }

    // MARK: - Reading keys

    /// ↓ scrolls a line — the scroll view's `verticalLineScroll`.
    func testDownArrowScrollsALine() throws {
        let (mounted, _, controller) = mount()
        defer { mounted.teardown() }
        mounted.scroll(toY: 1000)
        mounted.settle()
        XCTAssertEqual(offset(mounted), 1000, "mount never placed rows")

        _ = press(mounted, "\u{F701}", keyCode: 125, modifiers: [.numericPad, .function])

        XCTAssertEqual(offset(mounted), 1000 + mounted.scrollView.verticalLineScroll)
        XCTAssertEqual(controller.keys, [])
    }

    /// The host is asked first: a command it takes doesn't scroll, and one it
    /// leaves still does.
    func testTheHostIsAskedBeforeAKeyScrolls() throws {
        let (mounted, host, controller) = mount()
        defer { mounted.teardown() }
        host.handledCommands = [#selector(NSResponder.moveDown(_:))]
        mounted.scroll(toY: 1000)
        mounted.settle()
        XCTAssertEqual(offset(mounted), 1000, "mount never placed rows")

        _ = press(mounted, "\u{F701}", keyCode: 125, modifiers: [.numericPad, .function])
        XCTAssertEqual(offset(mounted), 1000, "the host took ↓")

        _ = press(mounted, "\u{F700}", keyCode: 126, modifiers: [.numericPad, .function])
        XCTAssertEqual(offset(mounted), 1000 - mounted.scrollView.verticalLineScroll, "↑ was left to scrolling")
        XCTAssertEqual(host.commands, [#selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:))])
        XCTAssertEqual(controller.keys, [])
    }

    /// A page is what the chrome leaves visible, less the scroll view's overlap —
    /// so no line scrolls from above the bar to under it without being shown.
    func testPageDownScrollsWhatTheChromeLeavesVisible() throws {
        let (mounted, _, controller) = mount(
            insets: NSEdgeInsets(top: 0, left: 0, bottom: 120, right: 0))
        defer { mounted.teardown() }
        mounted.scroll(toY: 1000)
        mounted.settle()
        XCTAssertEqual(offset(mounted), 1000, "mount never placed rows")

        _ = press(mounted, "\u{F72D}", keyCode: 121, modifiers: [.function])

        XCTAssertEqual(offset(mounted), 1000 + (720 - 120) - 10)
        XCTAssertEqual(controller.keys, [])
    }

    /// Home and End go to the ends of the scrollable range — End to the tail,
    /// above a bottom inset rather than under it.
    func testHomeAndEndGoToTheEnds() throws {
        let (mounted, _, controller) = mount(
            insets: NSEdgeInsets(top: 0, left: 0, bottom: 120, right: 0))
        defer { mounted.teardown() }
        mounted.scroll(toY: 1000)
        mounted.settle()
        XCTAssertEqual(offset(mounted), 1000, "mount never placed rows")

        _ = press(mounted, "\u{F72B}", keyCode: 119, modifiers: [.function])
        // A hundred rows of 40, and the 14pt gap between each two.
        let end: CGFloat = 100 * 40 + 99 * 14 + 120 - 720
        XCTAssertEqual(offset(mounted), end)

        _ = press(mounted, "\u{F729}", keyCode: 115, modifiers: [.function])
        XCTAssertEqual(offset(mounted), 0)
        XCTAssertEqual(controller.keys, [])
    }
}
