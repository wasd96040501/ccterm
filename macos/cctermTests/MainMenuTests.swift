import AppKit
import XCTest

@testable import ccterm

/// The main menu reaches the responder chain: every item sends its action
/// to nil, so AppKit asks the key window's chain to perform and to enable it.
@MainActor
final class MainMenuTests: XCTestCase {
    private func items(of menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(items(of:)) ?? []) }
    }

    func testEveryItemIsSentToNil() {
        let actions = items(of: MainMenu.make()).filter { $0.action != nil && $0.submenu == nil }
        XCTAssertFalse(actions.isEmpty)
        for item in actions { XCTAssertNil(item.target, item.title) }
    }

    func testTheFileMenuCarriesTheTabsCommands() throws {
        let file = try XCTUnwrap(MainMenu.make().items[1].submenu)
        let commands = file.items.filter { !$0.isSeparatorItem }.map {
            ($0.action.map(NSStringFromSelector) ?? "", $0.keyEquivalent, $0.keyEquivalentModifierMask)
        }
        XCTAssertEqual(
            commands.map(\.0), ["newTab:", "chooseFolder:", "closeTab:", "performClose:", "stopResponding:"])
        XCTAssertEqual(commands.map(\.1), ["t", "o", "w", "w", "."])
        XCTAssertEqual(commands[3].2, [.command, .shift], "Close Window is ⇧⌘W")
    }
}
