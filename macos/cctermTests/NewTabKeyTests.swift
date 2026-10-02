import AppKit
import XCTest

@testable import ccterm

/// Which key-downs the ⌘N monitor takes: exactly ⌘N, from every window ⌘T
/// works from, and not over a sheet or a modal session.
@MainActor
final class NewTabKeyTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows = []
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 300, height: 200), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }

    private func handles(_ window: NSWindow?, modal: NSWindow? = nil) -> Bool {
        NewTabKey.handles(modifiers: .command, characters: "n", in: window, modalWindow: modal)
    }

    func testCommandNIsTakenFromEveryWindowCommandTWorksFrom() {
        XCTAssertTrue(handles(makeWindow()), "the main window")
        XCTAssertTrue(handles(makeWindow()), "Settings, About, a panel")
        XCTAssertTrue(handles(nil), "no window key")
    }

    func testAModalSessionKeepsTheKey() {
        XCTAssertFalse(handles(makeWindow(), modal: makeWindow()))
        XCTAssertFalse(handles(nil, modal: makeWindow()))
    }

    func testASheetKeepsTheKeyAndSoDoesItsParent() {
        let main = makeWindow()
        let sheet = makeWindow()
        main.alphaValue = 0.01
        main.orderFront(nil)
        main.beginSheet(sheet)
        defer { main.endSheet(sheet) }
        XCTAssertNotNil(main.attachedSheet, "premise: the sheet is attached")

        XCTAssertFalse(handles(main))
        XCTAssertFalse(handles(sheet))
    }

    func testOnlyExactlyCommandN() {
        let main = makeWindow()
        for flags: NSEvent.ModifierFlags in [
            [], [.command, .shift], [.command, .option], [.control], [.command, .control],
        ] {
            XCTAssertFalse(NewTabKey.handles(modifiers: flags, characters: "n", in: main, modalWindow: nil), "\(flags)")
        }
        XCTAssertFalse(NewTabKey.handles(modifiers: .command, characters: "t", in: main, modalWindow: nil))
        XCTAssertFalse(NewTabKey.handles(modifiers: .command, characters: nil, in: main, modalWindow: nil))
        // Caps Lock is a state, not a chord.
        XCTAssertTrue(NewTabKey.handles(modifiers: [.command, .capsLock], characters: "n", in: main, modalWindow: nil))
    }
}
