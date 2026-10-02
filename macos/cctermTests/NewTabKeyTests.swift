import AppKit
import XCTest

@testable import ccterm

/// Which key-downs the ⌘N monitor takes: ⌘N in the main window and nowhere
/// else.
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

    func testCommandNInTheMainWindowIsTaken() {
        let main = makeWindow()
        XCTAssertTrue(NewTabKey.handles(modifiers: .command, characters: "n", in: main, mainWindow: main))
    }

    func testAnotherWindowKeepsItsKey() {
        let main = makeWindow()
        let settings = makeWindow()
        XCTAssertFalse(
            NewTabKey.handles(modifiers: .command, characters: "n", in: settings, mainWindow: main),
            "Settings or About is not where a tab opens from")
        XCTAssertFalse(NewTabKey.handles(modifiers: .command, characters: "n", in: nil, mainWindow: main))
        XCTAssertFalse(NewTabKey.handles(modifiers: .command, characters: "n", in: main, mainWindow: nil))
    }

    func testASheetOnTheMainWindowKeepsTheKey() {
        let main = makeWindow()
        let sheet = makeWindow()
        main.alphaValue = 0.01
        main.orderFront(nil)
        main.beginSheet(sheet)
        defer { main.endSheet(sheet) }
        XCTAssertNotNil(main.attachedSheet, "premise: the sheet is attached")

        XCTAssertFalse(NewTabKey.handles(modifiers: .command, characters: "n", in: main, mainWindow: main))
        XCTAssertFalse(NewTabKey.handles(modifiers: .command, characters: "n", in: sheet, mainWindow: main))
    }

    func testOnlyExactlyCommandN() {
        let main = makeWindow()
        for flags: NSEvent.ModifierFlags in [
            [], [.command, .shift], [.command, .option], [.control], [.command, .control],
        ] {
            XCTAssertFalse(NewTabKey.handles(modifiers: flags, characters: "n", in: main, mainWindow: main), "\(flags)")
        }
        XCTAssertFalse(NewTabKey.handles(modifiers: .command, characters: "t", in: main, mainWindow: main))
        XCTAssertFalse(NewTabKey.handles(modifiers: .command, characters: nil, in: main, mainWindow: main))
        // Caps Lock is a state, not a chord.
        XCTAssertTrue(NewTabKey.handles(modifiers: [.command, .capsLock], characters: "n", in: main, mainWindow: main))
    }
}
