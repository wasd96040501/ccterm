import AppKit
import DisplayModels
import XCTest

@testable import Components
@testable import ComponentsDesign

/// The Effort and Mode menus as built, item by item against the design's menus
/// sheet (`index.html` #lv-menus: *Effort · Sonnet 4.6*, *Permission mode · Fast
/// on*, *Permission mode · Haiku*): the head and its key hint, each item's
/// title, its reason or note under it, enabled, checked, its glyph, and the
/// hairline before Bypass; and the model list's sections. How they are drawn
/// is the style page's *Menus*.
@MainActor
final class ComposerMenuTests: XCTestCase {
    private typealias F = ComposerFixtures

    /// One menu line as the sheet lists it.
    private struct Line: Equatable, CustomStringConvertible {
        var title: String
        var subtitle: String? = nil
        var enabled = true
        var checked = false
        var glyph = true
        var kind = "item"

        static let separator = Line(title: "", enabled: false, glyph: false, kind: "separator")
        static func header(_ title: String) -> Line { Line(title: title, enabled: false, glyph: false, kind: "header") }

        var description: String {
            "\(kind) \(title) | \(subtitle ?? "-") \(enabled ? "" : "disabled ")\(checked ? "✓ " : "")\(glyph ? "glyph" : "")"
        }
    }

    private func lines(_ content: MenuContent) -> [Line] {
        content.rows.map { row in
            switch row {
            case .separator: return .separator
            case .header(.title(let title, _)): return .header(title)
            case .header(.account(_, let name, _, _)): return .header(name)
            case .item(let item):
                return Line(
                    title: item.title, subtitle: item.subtitle, enabled: item.isEnabled, checked: item.isChecked,
                    glyph: item.glyph != nil)
            }
        }
    }

    private func menu(_ menu: ComposerPresentation.Menu) -> MenuContent {
        ComposerMenu.content(of: menu, width: 240)
    }

    // MARK: - Effort

    func testEffortIsTheSheets() {
        let built = menu(F.state(model: "Sonnet 4.6", effort: ("High", 3)).effortMenu)
        XCTAssertEqual(
            lines(built),
            [
                .header("Effort · Sonnet 4.6"),
                Line(title: "Low"), Line(title: "Medium"),
                Line(title: "High", subtitle: "Default", checked: true),
                Line(title: "Extra High"),
                Line(title: "Max", subtitle: "This session only"),
            ])
    }

    /// Each level's meter and each mode's glyph is a row's: 16 pt.
    func testTheGlyphsAreRowSized() {
        let state = F.state(mode: .acceptEdits)
        for built in [menu(state.effortMenu), menu(state.modeMenu)] {
            for case .item(let item) in built.rows {
                XCTAssertEqual(item.glyph?.size, NSSize(width: 16, height: 16), item.title)
            }
        }
    }

    /// Choosing an item hands back its id.
    func testAnItemStandsForItsId() throws {
        let items = menu(F.idle.effortMenu).rows.compactMap { row -> MenuContent.Item? in
            if case .item(let item) = row { item } else { nil }
        }
        XCTAssertEqual(items[1].id as? ComposerMenu.Choice, .item("effort:medium"))
    }

    /// Every level's meter is its own image, the unfilled bars at 28 % ink.
    func testTheMeterHasAnAssetPerLevel() {
        let images = (0...5).map { ComposerGlyph.image(.effort(level: $0), size: 14) }
        for image in images { XCTAssertEqual(image?.size, NSSize(width: 14, height: 14)) }
        XCTAssertEqual(
            ComposerGlyph.image(.effort(level: nil), size: 14)?.tiffRepresentation, images[0]?.tiffRepresentation)
        XCTAssertNotEqual(images[1]?.tiffRepresentation, images[5]?.tiffRepresentation)
    }

    // MARK: - Permission Mode

    func testModeIsTheSheets() {
        XCTAssertEqual(
            lines(menu(F.state(mode: .acceptEdits).modeMenu)),
            [
                .header("Permission Mode"),
                Line(title: "Ask Permissions", subtitle: "Asks before edits and commands"),
                Line(
                    title: "Accept Edits", subtitle: "Edits files without asking; asks before commands", checked: true),
                Line(title: "Plan", subtitle: "Reads and plans; changes nothing"),
                Line(title: "Auto", subtitle: "Approves safe actions, asks when unsure"),
                Line(title: "Don’t Ask", subtitle: "Runs only what’s already allowed"),
                .separator,
                Line(title: "Bypass Permissions", subtitle: "Runs everything without asking"),
            ])
    }

    /// ⇧⇥ is the Mode head's key hint (`.mh kbd`).
    func testTheModeHeadCarriesItsKey() throws {
        guard case .header(.title(_, let hint))? = menu(F.idle.modeMenu).rows.first else {
            return XCTFail("no head")
        }
        XCTAssertEqual(hint, "⇧⇥")
    }

    // MARK: - Model

    /// The list keeps the height it has with every section unfolded, so
    /// *More Models* opens inside it and the popover never grows.
    func testTheModelListIsAsTallAsWithEveryModelShown() {
        let folded = ComposerMenu.modelContent(of: F.responding, expanded: [])
        let unfolded = ComposerMenu.modelContent(of: F.responding, expanded: [F.subscription])
        guard case .expanded(let all) = folded.listHeight, case .expanded(let same) = unfolded.listHeight else {
            return XCTFail("the model list is not as tall as when unfolded")
        }
        XCTAssertEqual(lines(MenuContent(rows: all)), lines(unfolded))
        XCTAssertEqual(lines(MenuContent(rows: same)), lines(MenuContent(rows: all)))
    }

    func testTheModelPanelListsTheNoteThenEachAccountsHeadModelsAndItsMoreRow() {
        let content = ComposerMenu.modelContent(of: F.responding, expanded: [])
        XCTAssertEqual(content.width, ComposerMenu.modelWidth)
        guard case .header(.title)? = content.rows.first else { return XCTFail("no note over the sections") }
        let heads = content.rows.compactMap { row -> String? in
            if case .header(.account(_, let name, _, _)) = row { name } else { nil }
        }
        XCTAssertEqual(heads, ["Claude Max", "Work Relay", "DeepSeek"])
        let more = content.rows.compactMap { row -> MenuContent.Item? in
            if case .item(let item) = row, item.isMore { item } else { nil }
        }
        XCTAssertEqual(more.count, 1)
        XCTAssertEqual(more.first?.id as? ComposerMenu.Choice, .more(F.subscription))
    }

    func testExpandingMoreModelsPutsTheFoldedOnesInPlace() {
        let content = ComposerMenu.modelContent(of: F.idle, expanded: [F.subscription])
        let titles = content.rows.compactMap { row -> String? in
            if case .item(let item) = row { item.title } else { nil }
        }
        XCTAssertEqual(titles.prefix(12).last, "Sonnet 4.6")
        XCTAssertFalse(content.rows.contains { if case .item(let item) = $0 { item.isMore } else { false } })
    }

    /// Fast Mode is a switch under the scroll, and keeps the menu open.
    func testFastModeIsASwitchUnderTheScroll() throws {
        let content = ComposerMenu.modelContent(of: F.fastRing, expanded: [])
        guard case .item(let fast)? = content.footer.first else { return XCTFail("no Fast Mode") }
        XCTAssertEqual(fast.id as? ComposerMenu.Choice, .fastMode)
        guard case .toggle(let isOn) = fast.trailing else { return XCTFail("not a switch") }
        XCTAssertTrue(isOn)
        XCTAssertTrue(fast.keepsMenuOpen)
    }
}
