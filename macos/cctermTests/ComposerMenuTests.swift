import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// The Effort and Mode menus as built, item by item against the design's menus
/// sheet (`index.html` #lv-menus: *Effort · Sonnet 4.6*, *Permission mode · Fast
/// on*, *Permission mode · Haiku*): the head and its key hint, each item's
/// title, its reason or note under it, enabled, checked, its glyph, and the
/// hairline before Bypass; and the model panel's sections. How they are drawn
/// is `MenuPanelSnapshotTests`'.
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

    private func menu(_ menu: ComposerModel.Menu) -> MenuContent {
        ComposerMenu.content(of: menu)
    }

    // MARK: - Effort · Sonnet 4.6

    func testEffortIsTheSheets() {
        let model = F.model(F.session(.idle), settings: F.settings("sonnet-4-6", effort: .high))
        let built = menu(model.effortMenu)
        XCTAssertEqual(
            lines(built),
            [
                .header(String(localized: "Effort · \("Sonnet 4.6")")),
                Line(title: String(localized: "Low")),
                Line(title: String(localized: "Medium")),
                Line(title: String(localized: "High"), subtitle: String(localized: "Default"), checked: true),
                Line(
                    title: String(localized: "Extra High"), subtitle: String(localized: "Not on \("Sonnet 4.6")"),
                    enabled: false),
                Line(title: String(localized: "Max"), subtitle: String(localized: "This session only")),
            ])
    }

    /// Each level's meter and each mode's glyph is a row's: 16 pt.
    func testTheGlyphsAreRowSized() {
        let model = F.model(F.session(.idle), settings: F.settings("opus", mode: .acceptEdits))
        for built in [menu(model.effortMenu), menu(model.modeMenu)] {
            for case .item(let item) in built.rows {
                XCTAssertEqual(item.glyph?.size, NSSize(width: 16, height: 16), item.title)
            }
        }
    }

    /// Choosing a level reports its change.
    func testAnItemStandsForItsChange() throws {
        let model = F.model(F.session(.idle), settings: F.settings("sonnet-4-6", effort: .high))
        let items = menu(model.effortMenu).rows.compactMap { row -> MenuContent.Item? in
            if case .item(let item) = row { item } else { nil }
        }
        XCTAssertEqual(items[1].id as? ComposerMenu.Choice, .change(.effort(.medium)))
    }

    // MARK: - Permission Mode

    private func modes(checked: PermissionMode, autoWhy: String) -> [Line] {
        func line(_ mode: PermissionMode, _ title: String, _ subtitle: String) -> Line {
            Line(title: title, subtitle: subtitle, checked: mode == checked)
        }
        return [
            .header(String(localized: "Permission Mode")),
            line(.default, String(localized: "Ask Permissions"), String(localized: "Asks before edits and commands")),
            line(
                .acceptEdits, String(localized: "Accept Edits"),
                String(localized: "Edits files without asking; asks before commands")),
            line(
                .plan, String(localized: "Plan (permission mode)", defaultValue: "Plan"),
                String(localized: "Reads and plans; changes nothing")),
            Line(title: String(localized: "Auto"), subtitle: autoWhy, enabled: false),
            line(.dontAsk, String(localized: "Don’t Ask"), String(localized: "Runs only what’s already allowed")),
            .separator,
            Line(
                title: String(localized: "Bypass Permissions"),
                subtitle: String(localized: "Allow it in Settings › General"), enabled: false),
        ]
    }

    func testModeWithFastOnIsTheSheets() {
        let model = F.model(F.session(.idle), settings: F.settings("opus", mode: .acceptEdits, fast: true))
        XCTAssertEqual(
            lines(menu(model.modeMenu)),
            modes(checked: .acceptEdits, autoWhy: String(localized: "Unavailable while Fast Mode is on")))
    }

    func testModeOnHaikuIsTheSheets() {
        let model = F.model(F.session(.idle), settings: F.settings("haiku", effort: nil, mode: .default))
        XCTAssertEqual(
            lines(menu(model.modeMenu)), modes(checked: .default, autoWhy: String(localized: "Not on \("Haiku 4.5")")))
    }

    /// ⇧⇥ is the Mode head's key hint (`.mh kbd`).
    func testTheModeHeadCarriesItsKey() throws {
        let model = F.model(F.session(.idle), settings: F.settings("opus", mode: .acceptEdits))
        guard case .header(.title(_, let hint))? = menu(model.modeMenu).rows.first else {
            return XCTFail("no head")
        }
        XCTAssertEqual(hint, "⇧⇥")
    }

    // MARK: - Model

    func testTheModelPanelListsTheNoteThenEachAccountsHeadModelsAndItsMoreRow() {
        let model = F.model(F.session(.responding), settings: F.settings("opus"))
        let content = ComposerMenu.modelContent(of: model, expanded: [])
        XCTAssertTrue(content.isPanel)
        guard case .header(.title)? = content.rows.first else { return XCTFail("no note over the sections") }
        let heads = content.rows.compactMap { row -> String? in
            if case .header(.account(_, let name, _, _)) = row { name } else { nil }
        }
        XCTAssertEqual(heads, ["Claude Max", "Work Relay", "DeepSeek"])
        let more = content.rows.compactMap { row -> MenuContent.Item? in
            if case .item(let item) = row, item.isMore { item } else { nil }
        }
        XCTAssertEqual(more.map(\.title), [String(localized: "\(7) More Models")])
        XCTAssertEqual(more.first?.id as? ComposerMenu.Choice, .more(F.subscription))
    }

    func testExpandingMoreModelsPutsTheFoldedOnesInPlace() {
        let model = F.model(.draft, settings: F.settings("opus"))
        let content = ComposerMenu.modelContent(of: model, expanded: [F.subscription])
        let titles = content.rows.compactMap { row -> String? in
            if case .item(let item) = row { item.title } else { nil }
        }
        XCTAssertEqual(titles.prefix(12).last, "Sonnet 4.6")
        XCTAssertFalse(content.rows.contains { if case .item(let item) = $0 { item.isMore } else { false } })
    }

    /// Fast Mode is a switch under the scroll, and keeps the menu open.
    func testFastModeIsASwitchUnderTheScroll() throws {
        let model = F.model(F.session(.idle), settings: F.settings("opus", fast: true))
        let content = ComposerMenu.modelContent(of: model, expanded: [])
        guard case .item(let fast)? = content.footer.first else { return XCTFail("no Fast Mode") }
        XCTAssertEqual(fast.id as? ComposerMenu.Choice, .fastMode)
        guard case .toggle(let isOn) = fast.trailing else { return XCTFail("not a switch") }
        XCTAssertTrue(isOn)
        XCTAssertTrue(fast.keepsMenuOpen)
    }
}
