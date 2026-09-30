import ExactListTestSupport
import XCTest

@testable import ExactList

/// First responder and key commands: §11.
///
/// Each method proves the requirement in its name. `SpecCoverageTests` checks
/// that every ID in `SPEC.md` has one.
@MainActor
final class KeyboardTests: XCTestCase {

    /// A click takes focus. Real key events go through the standard key
    /// bindings: the delegate is offered each command first; the list answers
    /// line, page, beginning and end by AppKit's own amounts; anything else
    /// reaches the next responder as the original event.
    func testK1_keys() async throws {
        let stage = ListStage(size: NSSize(width: 400, height: 300))
        defer { stage.teardown() }
        let host = RecordingHost(count: 300) { _, _ in 30 }
        let list = ExactListView(dataSource: host, delegate: host)
        let recorder = KeyRecorder()
        recorder.translatesAutoresizingMaskIntoConstraints = false
        list.translatesAutoresizingMaskIntoConstraints = false
        stage.rootView.addSubview(recorder)
        recorder.addSubview(list)
        NSLayoutConstraint.activate([
            recorder.leadingAnchor.constraint(equalTo: stage.rootView.leadingAnchor),
            recorder.trailingAnchor.constraint(equalTo: stage.rootView.trailingAnchor),
            recorder.topAnchor.constraint(equalTo: stage.rootView.topAnchor),
            recorder.bottomAnchor.constraint(equalTo: stage.rootView.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: recorder.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: recorder.trailingAnchor),
            list.topAnchor.constraint(equalTo: recorder.topAnchor),
            list.bottomAnchor.constraint(equalTo: recorder.bottomAnchor),
        ])
        await stage.settle()
        let scroll = try XCTUnwrap(list.subviews.compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertTrue(document.acceptsFirstResponder)

        EventSynthesizer.click(in: stage.window, at: NSPoint(x: 200, y: 150))
        await stage.settle()
        XCTAssertTrue(stage.window.firstResponder === document, "a click takes focus")

        func press(_ characters: String, _ keyCode: UInt16) async {
            EventSynthesizer.key(in: stage.window, characters: characters, keyCode: keyCode)
            await stage.settle()
        }
        let line = scroll.verticalLineScroll
        let page = list.bounds.height - scroll.verticalPageScroll

        host.resetCalls()
        await press(String(UnicodeScalar(NSDownArrowFunctionKey)!), 125)
        XCTAssertEqual(offset(of: list), line, "down arrow: moveDown, one line")
        XCTAssertEqual(commands(host), [#selector(NSResponder.moveDown(_:))], "offered to the delegate first")
        await press(String(UnicodeScalar(NSPageDownFunctionKey)!), 121)
        XCTAssertEqual(offset(of: list), line + page, "page down: the height of U minus verticalPageScroll")
        await press(String(UnicodeScalar(NSUpArrowFunctionKey)!), 126)
        XCTAssertEqual(offset(of: list), page, "up arrow: moveUp")
        await press(String(UnicodeScalar(NSEndFunctionKey)!), 119)
        XCTAssertEqual(offset(of: list), 300 * 30 - list.bounds.height, "end: scrollToEndOfDocument")
        await press(String(UnicodeScalar(NSPageUpFunctionKey)!), 116)
        XCTAssertEqual(offset(of: list), 300 * 30 - list.bounds.height - page, "page up")
        await press(String(UnicodeScalar(NSHomeFunctionKey)!), 115)
        XCTAssertEqual(offset(of: list), 0, "home: scrollToBeginningOfDocument")

        host.handledCommands = [#selector(NSResponder.moveDown(_:))]
        await press(String(UnicodeScalar(NSDownArrowFunctionKey)!), 125)
        XCTAssertEqual(offset(of: list), 0, "the delegate claimed it")
        host.onCommand = { list, _ in list.scrollToRow(100, at: .top) }
        await press(String(UnicodeScalar(NSDownArrowFunctionKey)!), 125)
        XCTAssertEqual(offset(of: list), 100 * 30, "the delegate may scroll from it")
        host.onCommand = nil
        await press(String(UnicodeScalar(NSHomeFunctionKey)!), 115)

        XCTAssertEqual(recorder.keys, [])
        await press("a", 0)
        await press("\r", 36)
        XCTAssertEqual(recorder.keys.map(\.characters), ["a", "\r"], "the original events, up the chain")
        XCTAssertEqual(recorder.keys.map(\.keyCode), [0, 36])
        XCTAssertTrue(commands(host).contains(#selector(NSResponder.insertNewline(_:))), "offered first")
        XCTAssertEqual(offset(of: list), 0)
    }

    // MARK: - Helpers

    private func offset(of list: ExactListView) -> CGFloat {
        -list.rect(ofRow: 0).minY
    }

    private func commands(_ host: RecordingHost) -> [Selector] {
        host.calls.compactMap { if case .doCommand(let selector) = $0 { selector } else { nil } }
    }

    /// The list's superview, recording the key events that reach it.
    private final class KeyRecorder: NSView {
        private(set) var keys: [NSEvent] = []
        override func keyDown(with event: NSEvent) {
            keys.append(event)
        }
    }
}
