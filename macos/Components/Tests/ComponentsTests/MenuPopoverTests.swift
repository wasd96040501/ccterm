import AppKit
import XCTest

@testable import Components
@testable import ComponentsDesign

/// `MenuPopover` opened for real, from a button in a window off screen: what
/// it shows the first time it opens, its one size while open, its keys, and
/// how its button opens and closes it.
@MainActor
final class MenuPopoverTests: XCTestCase {
    private var stage: Stage!
    private var chosen: [AnyHashable] = []
    private var searches: [String] = []

    override func setUp() {
        stage = Stage()
        // The fade is AppKit's; these tests cover what the popover does once
        // it has closed, so it closes at once.
        stage.popover.animates = false
        chosen = []
        searches = []
        stage.popover.onChoose = { [unowned self] item in chosen.append(item.id) }
        stage.popover.onSearch = { [unowned self] words in
            searches.append(words)
            stage.popover.configure(with: MenuFixtures.branch(query: words))
        }
    }

    override func tearDown() {
        stage.popover.close()
        stage.window.close()
    }

    private func open(_ content: MenuContent) {
        stage.popover.configure(with: content)
        stage.popover.show(from: stage.button, above: false)
    }

    private var list: NSView {
        get throws { try XCTUnwrap(stage.popover.contentViewController?.view) }
    }

    private var table: NSTableView {
        get throws { try XCTUnwrap(list.descendant(NSTableView.self)) }
    }

    private var popoverWindow: NSWindow {
        get throws { try XCTUnwrap(list.window) }
    }

    private func press(_ keyCode: UInt16, _ characters: String) throws {
        let window = try popoverWindow
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                keyCode: keyCode))
        window.sendEvent(event)
    }

    private func pressDown() throws { try press(125, String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))) }
    private func pressReturn() throws { try press(36, "\r") }
    private func pressEscape() throws { try press(53, "\u{1b}") }

    // MARK: - Opening

    /// The first open shows every row, laid out at the popover's width.
    func testTheFirstOpenShowsItsRows() throws {
        let content = ComposerMenu.content(of: .effort, in: MenuFixtures.composer)
        open(content)
        XCTAssertTrue(stage.popover.isShown)
        let table = try table
        XCTAssertEqual(table.numberOfRows, content.rows.count)
        for row in 0..<table.numberOfRows {
            let view = try XCTUnwrap(table.view(atColumn: 0, row: row, makeIfNecessary: false), "row \(row)")
            XCTAssertGreaterThan(view.frame.height, 10, "row \(row)")
            XCTAssertGreaterThan(view.frame.width, 150, "row \(row)")
        }
        XCTAssertEqual(stage.popover.contentSize.width, 240)
        XCTAssertEqual(stage.button.state, .on)
    }

    /// As tall as its rows: the last row ends inside the list.
    func testAShortMenuIsAsTallAsItsRows() throws {
        open(MenuFixtures.folder)
        let table = try table
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        let last = table.rect(ofRow: table.numberOfRows - 1)
        XCTAssertLessThanOrEqual(last.maxY, scroll.contentView.bounds.height)
        XCTAssertGreaterThan(last.maxY, scroll.contentView.bounds.height - 20)
    }

    /// A short menu shows all its rows: the list is as tall as they are,
    /// measured before it opens, so nothing scrolls.
    func testAShortMenuShowsEveryRowWithoutScrolling() throws {
        let contents = [
            ComposerMenu.content(of: .effort, in: MenuFixtures.composer),
            ComposerMenu.content(of: .mode, in: MenuFixtures.composer), MenuFixtures.folder,
        ]
        for content in contents {
            open(content)
            let table = try table
            let scroll = try XCTUnwrap(table.enclosingScrollView)
            let rows = table.rect(ofRow: table.numberOfRows - 1).maxY + table.rect(ofRow: 0).minY
            XCTAssertEqual(scroll.contentView.bounds.height, rows, accuracy: 1, "\(content.minWidth)")
            stage.popover.close()
        }
    }

    /// A long list stops at 1.618 times the menu's least width and scrolls;
    /// Fast Mode stays under it.
    func testALongListStopsAtTheGoldenRatioAndScrolls() throws {
        let content = ComposerMenu.content(of: .model, in: MenuFixtures.composer)
        open(content)
        let table = try table
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        let rows = table.rect(ofRow: table.numberOfRows - 1).maxY + table.rect(ofRow: 0).minY
        XCTAssertLessThanOrEqual(stage.popover.contentSize.height, (content.minWidth * 1.618).rounded(.up))
        XCTAssertLessThan(scroll.contentView.bounds.height, rows, "the list scrolls")
        XCTAssertGreaterThan(stage.popover.contentSize.height, scroll.frame.height, "Fast Mode under the list")
    }

    /// The popover widens for its rows: a folder's path is shown whole.
    func testItWidensForItsRows() throws {
        open(MenuFixtures.folder)
        let paths = try list.descendants(NSTextField.self).filter { $0.stringValue.hasPrefix("~/") && !$0.isHidden }
        XCTAssertFalse(paths.isEmpty)
        for path in paths {
            XCTAssertGreaterThanOrEqual(path.frame.width, path.intrinsicContentSize.width - 0.5, path.stringValue)
        }
        XCTAssertGreaterThanOrEqual(stage.popover.contentSize.width, 320)
        XCTAssertLessThanOrEqual(stage.popover.contentSize.width, (320 * 1.618).rounded(.up))
    }

    // MARK: - One size while open

    /// Searching changes the rows, never the box; nothing matching says so.
    func testSearchingKeepsTheSize() throws {
        open(MenuFixtures.branch())
        let size = stage.popover.contentSize
        stage.popover.configure(with: MenuFixtures.branch(query: "zzz"))
        XCTAssertEqual(stage.popover.contentSize, size)
        XCTAssertEqual(try table.numberOfRows, 0)
        let empty = try XCTUnwrap(list.descendants(NSTextField.self).first { $0.stringValue == "No Matching Branches" })
        XCTAssertFalse(empty.isHidden)
        stage.popover.configure(with: MenuFixtures.branch(query: "#327"))
        XCTAssertEqual(stage.popover.contentSize, size)
        XCTAssertTrue(empty.isHidden)
    }

    // MARK: - Keys

    /// ↓ goes to the first item that can be chosen, then past a greyed one.
    func testArrowsSkipWhatCantBeChosen() throws {
        open(MenuFixtures.branch())
        let table = try table
        XCTAssertEqual(table.selectedRow, -1, "nothing selected on opening")
        try pressDown()
        XCTAssertEqual(table.selectedRow, 1, "main, under Local")
        try pressDown()
        XCTAssertEqual(table.selectedRow, 3, "past live-session-design, which is greyed")
    }

    /// ↩ takes the selected item and closes the popover.
    func testReturnChooses() throws {
        open(ComposerMenu.content(of: .effort, in: MenuFixtures.composer))
        try pressDown()
        try pressReturn()
        XCTAssertEqual(chosen.count, 1)
        XCTAssertFalse(stage.popover.isShown)
        XCTAssertEqual(stage.button.state, .off)
    }

    /// In the search field, ↩ takes the first match.
    func testReturnInTheSearchTakesTheFirstMatch() throws {
        open(MenuFixtures.branch())
        stage.popover.configure(with: MenuFixtures.branch(query: "gutter"))
        try pressReturn()
        XCTAssertEqual(chosen, [AnyHashable("fix-gutter-overflow")])
    }

    func testEscapeCloses() throws {
        open(ComposerMenu.content(of: .mode, in: MenuFixtures.composer))
        try pressEscape()
        XCTAssertFalse(stage.popover.isShown)
    }

    /// Typing goes to the search field, which reports it.
    func testTypingSearches() throws {
        open(MenuFixtures.branch())
        let field = try XCTUnwrap(list.descendant(NSSearchField.self))
        XCTAssertTrue(try popoverWindow.firstResponder === field.currentEditor())
        field.stringValue = "#327"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        XCTAssertEqual(searches, ["#327"])
    }

    // MARK: - The button

    /// The button is on while the popover is open from it, whichever way it
    /// closes.
    func testItsButtonIsOnWhileItIsOpen() throws {
        open(MenuFixtures.folder)
        XCTAssertEqual(stage.popover.anchor, stage.button)
        XCTAssertEqual(stage.button.state, .on)
        try pressEscape()
        XCTAssertFalse(stage.popover.isShown)
        XCTAssertEqual(stage.button.state, .off)
    }

    /// Opened from another button, it closes at the first, which goes off.
    func testOpeningFromAnotherButtonMovesIt() {
        open(MenuFixtures.folder)
        stage.popover.show(from: stage.other, above: false)
        XCTAssertTrue(stage.popover.isShown)
        XCTAssertEqual(stage.popover.anchor, stage.other)
        XCTAssertEqual([stage.button.state, stage.other.state], [.off, .on])
    }

    /// Moving from one menu to another with fewer, shorter rows, as the New
    /// view does from a long branch list to the folder: the new rows are
    /// handed over while the old menu is still open — rows that would come
    /// into view are the new content's, never the old count's.
    func testAnotherMenuWithFewerRowsReplacesAnOpenOne() throws {
        let branches = MenuContent(
            rows: (0..<30).map {
                .item(MenuContent.Item(id: $0, title: "branch-\($0)", subtitle: "Checked out in another worktree"))
            },
            searchPlaceholder: "Filter", minWidth: 300, listHeight: 264)
        open(branches)
        let longer = try table.numberOfRows
        // The open menu's rows laid out, as they are on screen.
        try popoverWindow.layoutIfNeeded()
        try popoverWindow.displayIfNeeded()
        var shown = 0
        try table.enumerateAvailableRowViews { _, _ in shown += 1 }
        XCTAssertGreaterThan(shown, 0, "premise: the open menu's rows are laid out")
        stage.popover.configure(with: MenuFixtures.folder)
        stage.popover.show(from: stage.other, above: false)
        let table = try table
        XCTAssertLessThan(MenuFixtures.folder.rows.count, longer, "premise: the second menu is shorter")
        XCTAssertEqual(table.numberOfRows, MenuFixtures.folder.rows.count)
        XCTAssertEqual(stage.popover.anchor, stage.other)
    }

    /// A switch leaves the popover open; a choice closes it.
    func testWhatKeepsItOpen() {
        XCTAssertTrue(MenuContent.Item(id: 0, title: "Fast Mode", trailing: .toggle(isOn: false)).isToggle)
        XCTAssertFalse(MenuContent.Item(id: 0, title: "Opus 5.5").isToggle)
    }
}

extension NSView {
    /// The first view of `type` in this view's tree, depth first.
    func descendant<T: NSView>(_ type: T.Type) -> T? {
        descendants(type).first
    }

    func descendants<T: NSView>(_ type: T.Type) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + $0.descendants(type) }
    }
}
