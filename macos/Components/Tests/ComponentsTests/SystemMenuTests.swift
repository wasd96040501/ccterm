import AppKit
import XCTest

@testable import Components
@testable import ComponentsDesign

/// A menu that is not a panel, as a real `NSMenu`: the design's rows at the
/// design's widths, each item chosen through the menu's own action.
@MainActor
final class SystemMenuTests: XCTestCase {
    private func menu(_ content: MenuContent) -> SystemMenu {
        let menu = SystemMenu()
        menu.configure(with: content)
        return menu
    }

    /// The menu is the design's size: the rows' views at the menu's width
    /// (`.lv-menu` with its padding) and their heights, and the system's
    /// chrome only above and under them — the design's 5 each side.
    func testTheMenuIsTheDesignsSize() {
        for (content, size) in [
            (MenuFixtures.effort, NSSize(width: 240, height: 186.16)),
            (MenuFixtures.mode, NSSize(width: 330, height: 281.51)),
        ] {
            let menu = menu(content)
            XCTAssertEqual(menu.menu.items.compactMap(\.view).count, menu.menu.items.count, "an item has no view")
            XCTAssertEqual(menu.menu.size.width, size.width, accuracy: 2)
            XCTAssertEqual(menu.menu.size.height, size.height, accuracy: 0.5)
        }
        // A menu is as wide as the panel would draw it.
        let folder = menu(MenuFixtures.folder)
        XCTAssertEqual(folder.menu.size.width, MenuMetrics.width(of: MenuFixtures.folder), accuracy: 0.5)
    }

    /// Return or a click reports the item; the head and the hairline can't be
    /// chosen, and type-select reads every item's title.
    func testItemsAreChosenThroughTheMenu() throws {
        let menu = menu(MenuFixtures.mode)
        var chosen: [MenuContent.Item] = []
        menu.onChoose = { chosen.append($0) }
        let items = menu.menu.items

        XCTAssertEqual(items.filter { !$0.isEnabled }.count, 2, "only the head and the hairline are out of reach")
        XCTAssertEqual(
            items.filter(\.isEnabled).map(\.title),
            ["Ask Permissions", "Accept Edits", "Plan", "Auto", "Don’t Ask", "Bypass Permissions"])
        let plan = try XCTUnwrap(items.firstIndex { $0.title == "Plan" })
        menu.menu.performActionForItem(at: plan)

        XCTAssertEqual(chosen.map(\.title), ["Plan"])
    }
}
