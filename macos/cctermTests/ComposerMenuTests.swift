import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// The Effort and Mode menus as built, item by item against the design's menus
/// sheet (`index.html` #lv-menus: *Effort · Sonnet 4.6*, *Permission mode · Fast
/// on*, *Permission mode · Haiku*). They are `NSMenu`s — AppKit draws them only
/// while they track — so what is compared is what the menu is made of: the
/// header and its key hint, each item's title, its reason or note under it,
/// enabled, checked, its glyph, and the separator before Bypass.
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

    @objc private func chosen(_ sender: NSMenuItem) {}

    private func lines(_ menu: NSMenu) -> [Line] {
        menu.items.map { item in
            if item.isSeparatorItem { return .separator }
            // The words before the key hint, which has its own test.
            if item.isSectionHeader { return .header(item.title.components(separatedBy: "\t")[0]) }
            return Line(
                title: item.title, subtitle: item.subtitle, enabled: item.isEnabled, checked: item.state == .on,
                glyph: item.image != nil)
        }
    }

    private func menu(_ menu: ComposerModel.Menu) -> NSMenu {
        ComposerMenu.make(menu, target: self, action: #selector(chosen(_:)))
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

    /// Each level's meter is a row's glyph: 16 pt.
    func testTheGlyphsAreRowSized() {
        let model = F.model(F.session(.idle), settings: F.settings("opus", mode: .acceptEdits))
        for built in [menu(model.effortMenu), menu(model.modeMenu)] {
            for item in built.items where item.image != nil {
                XCTAssertLessThanOrEqual(item.image!.size.height, 16, item.title)
                XCTAssertLessThanOrEqual(item.image!.size.width, 16, item.title)
            }
        }
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

    /// ⇧⇥ ends where the items' key equivalents would, and the header never
    /// makes the menu wider than its items do.
    func testTheModeHintEndsAtTheMenusEdgeWithoutWideningIt() throws {
        let model = F.model(F.session(.idle), settings: F.settings("opus", mode: .acceptEdits))
        let built = menu(model.modeMenu)
        let header = try XCTUnwrap(built.items.first { $0.isSectionHeader })
        let hinted = try XCTUnwrap(header.attributedTitle)
        XCTAssertTrue(hinted.string.hasSuffix("\t⇧⇥"), hinted.string)
        let style = try XCTUnwrap(hinted.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.tabStops.first?.alignment, .right)

        let width = built.size.width
        header.attributedTitle = nil
        header.title = String(localized: "Permission Mode")
        XCTAssertEqual(width, built.size.width, accuracy: 0.5, "the hint widened the menu")
    }
}
