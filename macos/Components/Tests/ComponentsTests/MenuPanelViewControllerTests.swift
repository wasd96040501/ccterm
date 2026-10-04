import AppKit
import XCTest

@testable import Components
@testable import ComponentsDesign

/// The one menu (`MenuPanelViewController`) held to the design's numbers and
/// to a menu's manners: each pop-up the size the playground draws it (measured
/// in Chrome from preview-live.css: Effort 240 × 186.2, Mode 330 × 281.5,
/// Folder 295 × 166.7, Branch 300 × 287.8, Model 300 × 424.3), its rows the
/// sheet's heights, ↑ ↓ over what can be chosen, ↩ and ⎋, the filter, and the
/// items that keep it open.
@MainActor
final class MenuPanelViewControllerTests: XCTestCase {
    private final class Recorder: MenuPanelViewControllerDelegate {
        var chosen: [AnyHashable] = []
        var filters: [String] = []
        var cancels = 0

        func menuPanelViewController(
            _ menuPanelViewController: MenuPanelViewController, didChoose item: MenuContent.Item
        ) {
            chosen.append(item.id)
        }

        func menuPanelViewController(_ menuPanelViewController: MenuPanelViewController, didChangeFilter text: String) {
            filters.append(text)
        }

        func menuPanelViewControllerDidCancel(_ menuPanelViewController: MenuPanelViewController) {
            cancels += 1
        }

        func menuPanelViewControllerDidChangeSize(_ menuPanelViewController: MenuPanelViewController) {}
    }

    private var window: NSWindow!
    private var recorder: Recorder!

    override func setUp() {
        recorder = Recorder()
    }

    override func tearDown() {
        window?.close()
    }

    /// `content` in a menu mounted off screen, laid out.
    private func mount(_ content: MenuContent) -> MenuPanelViewController {
        let menu = MenuPanelViewController()
        menu.delegate = recorder
        menu.configure(with: content)
        window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: menu.preferredSize),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = menu
        window.setContentSize(menu.preferredSize)
        menu.view.layoutSubtreeIfNeeded()
        return menu
    }

    private func table(in menu: MenuPanelViewController) throws -> NSTableView {
        let scroll = try XCTUnwrap(menu.view.subviews.compactMap { $0 as? NSScrollView }.first)
        return try XCTUnwrap(scroll.documentView as? NSTableView)
    }

    // MARK: - The design's sizes

    private func assertSize(
        _ content: MenuContent, _ width: CGFloat, _ height: CGFloat, widthAccuracy: CGFloat = 0.5,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let size = mount(content).preferredSize
        XCTAssertEqual(size.width, width, accuracy: widthAccuracy, "width", file: file, line: line)
        XCTAssertEqual(size.height, height, accuracy: 0.5, "height", file: file, line: line)
    }

    func testEffortIsTheDesignsSize() {
        assertSize(MenuFixtures.effort, 240, 196.16)
    }

    /// 300 wide, a subtitle wrapping under its title.
    func testModeIsTheDesignsSize() {
        assertSize(MenuFixtures.mode, 300, 305.5)
    }

    /// The filter, then 264 of list whatever it leaves: the box never moves
    /// while you type.
    func testTheBranchKeepsItsSizeWhateverTheFilterLeaves() {
        for query in ["", "gutter", "#327", "zzz"] {
            assertSize(MenuFixtures.branch(query: query), 300, 297)
        }
    }

    /// As tall as with every model shown, 360 at most; Fast Mode's two-line
    /// row under it.
    func testTheModelListIsTheDesignsSize() {
        assertSize(MenuFixtures.model, 300, 430.84)
    }

    /// Nothing left: the list keeps its size and says so in its middle.
    func testNothingMatchingSaysSo() throws {
        let menu = mount(MenuFixtures.branch(query: "zzz"))
        let label = try XCTUnwrap(
            menu.view.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "No Matching Branches" })
        XCTAssertFalse(label.isHidden)
        XCTAssertEqual(try table(in: menu).numberOfRows, 0)
        let shown = mount(MenuFixtures.branch())
        XCTAssertTrue(shown.view.subviews.compactMap { $0 as? NSTextField }.allSatisfy { $0.isHidden })
    }

    func testRowsAreTheSheetsHeights() {
        let content = MenuContent(rows: [])
        func height(_ row: MenuContent.Row) -> CGFloat { MenuMetrics.height(of: row, width: 300, content: content) }
        XCTAssertEqual(height(.item(MenuContent.Item(id: 0, title: "Low"))), 24.85, accuracy: 0.02)
        XCTAssertEqual(
            height(.item(MenuContent.Item(id: 0, title: "High", subtitle: "Default"))), 39.85, accuracy: 0.02)
        XCTAssertEqual(height(.header(.title("Recent"))), 21.95, accuracy: 0.02)
        XCTAssertEqual(height(.separator), 10.5)
        XCTAssertEqual(
            height(.header(.account(mark: NSImage(), name: "Claude Max", detail: "Subscription", note: nil))), 29.94,
            accuracy: 0.02)
        XCTAssertEqual(
            height(.header(.account(mark: NSImage(), name: "Work Relay", detail: "", note: "Restarts the session"))),
            45.88, accuracy: 0.02)
    }

    /// The hairline over the footer (`.mfoot` border-top): 0.5 pt, the panel's
    /// width, in the separator colour.
    func testTheFooterHasItsHairline() throws {
        let menu = mount(MenuFixtures.model)
        window.displayIfNeeded()
        let line = try XCTUnwrap(menu.view.subviews.compactMap { $0 as? MenuHairline }.first)
        XCTAssertFalse(line.isHidden)
        XCTAssertEqual(line.frame.height, 0.5)
        XCTAssertEqual(line.frame.width, menu.view.bounds.width)
        let colour = try XCTUnwrap(line.layer?.backgroundColor)
        XCTAssertEqual(colour.alpha, 0.098, accuracy: 0.01, "\(colour) \(String(describing: line.layer))")
    }

    // MARK: - Manners

    /// ↓ from nothing lands on the first item, and skips what can't be chosen.
    func testArrowsSkipWhatCantBeChosen() throws {
        let menu = mount(MenuFixtures.branch())
        let table = try table(in: menu)
        XCTAssertEqual(table.selectedRow, -1, "a menu at rest highlights nothing")
        let field = try XCTUnwrap(menu.initialFirstResponder as? NSTextField)
        let editor = NSTextView()
        _ = menu.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(table.selectedRow, 1, "main, under Local")
        _ = menu.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(table.selectedRow, 3, "past live-session-design, which is greyed")
    }

    /// ↩ in the filter takes the first match, as Xcode's branch picker does.
    func testReturnInTheFilterTakesTheFirstMatch() throws {
        let menu = mount(MenuFixtures.branch(query: "gutter"))
        let field = try XCTUnwrap(menu.initialFirstResponder as? NSTextField)
        _ = menu.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(recorder.chosen, [AnyHashable("fix-gutter-overflow")])
    }

    func testEscapeCancels() throws {
        let menu = mount(MenuFixtures.mode)
        try table(in: menu).cancelOperation(nil)
        XCTAssertEqual(recorder.cancels, 1)
    }

    func testTypingInTheFilterIsReported() throws {
        let menu = mount(MenuFixtures.branch())
        let field = try XCTUnwrap(menu.initialFirstResponder as? NSTextField)
        field.stringValue = "#327"
        menu.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(recorder.filters, ["#327"])
    }

    /// A switch and a fold leave the menu open; a choice closes it.
    func testWhatKeepsTheMenuOpen() {
        XCTAssertTrue(MenuContent.Item(id: 0, title: "Fast Mode", trailing: .toggle(isOn: false)).keepsMenuOpen)
        XCTAssertTrue(MenuContent.Item(id: 0, title: "7 More Models", isMore: true).keepsMenuOpen)
        XCTAssertFalse(MenuContent.Item(id: 0, title: "Opus 5.5").keepsMenuOpen)
    }

    /// Words start in one column: with a glyph anywhere, every item keeps the
    /// glyph column (58); with none, they start at 34 (`.mi.nog`).
    func testTheWordsColumn() {
        XCTAssertTrue(MenuFixtures.mode.hasGlyphColumn)
        XCTAssertFalse(MenuFixtures.branch().hasGlyphColumn)
        XCTAssertEqual(MenuMetrics.wordsX(glyphColumn: true), 58)
        XCTAssertEqual(MenuMetrics.wordsX(glyphColumn: false), 34)
    }
}
