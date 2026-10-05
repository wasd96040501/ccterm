import AppKit
import DisplayModels
import XCTest

@testable import Components

/// Accounts' components, driven as their controls are and read off what
/// they show.
final class AccountsTests: XCTestCase {
    private func shown<V: NSView>(_ type: V.Type, in root: NSView) -> [V] {
        var found: [V] = []
        func walk(_ view: NSView) {
            if let view = view as? V, !view.isHiddenOrHasHiddenAncestor { found.append(view) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    private func row(
        _ accessory: AccountRowContent.Accessory, mark: AccountRowContent.Mark = .provider
    )
        -> AccountRowView
    {
        let row = AccountRowView()
        row.frame = NSRect(x: 0, y: 0, width: 480, height: 52)
        row.configure(
            with: AccountRowContent(
                title: "Team Relay", subtitle: "relay.example.com", mark: mark, accessory: accessory))
        row.layoutSubtreeIfNeeded()
        return row
    }

    // MARK: - A row

    func testRowsTrailingEdgeIsItsAccessory() {
        let info = row(.info)
        XCTAssertEqual(shown(NSButton.self, in: info).count, 1)
        XCTAssertTrue(shown(NSProgressIndicator.self, in: info).isEmpty)

        let button = row(.button("Sign In…"))
        XCTAssertEqual(shown(NSButton.self, in: button).map(\.title), ["Sign In…"])

        let progress = row(.progress)
        XCTAssertTrue(shown(NSButton.self, in: progress).isEmpty)
        XCTAssertEqual(shown(NSProgressIndicator.self, in: progress).count, 1)
    }

    func testInfoOpensTheAccountAndTheButtonActs() {
        let info = row(.info)
        var opened = 0
        info.onOpen = { opened += 1 }
        shown(NSButton.self, in: info).first?.performClick(nil)
        XCTAssertEqual(opened, 1)

        let button = row(.button("Sign In…"))
        var acted = 0
        button.onAction = { acted += 1 }
        shown(NSButton.self, in: button).first?.performClick(nil)
        XCTAssertEqual(acted, 1)
    }

    func testReconfiguringReplacesTheAccessory() {
        let row = row(.progress)
        row.configure(with: AccountRowContent(title: "name@example.com", subtitle: "", mark: .claude, accessory: .info))
        XCTAssertTrue(shown(NSProgressIndicator.self, in: row).isEmpty)
        XCTAssertEqual(shown(NSButton.self, in: row).count, 1)
    }

    func testANameWithoutAMarkStartsAtTheEdge() {
        let marked = row(.info)
        let bare = row(.info, mark: .none)
        let title: (AccountRowView) -> CGFloat = { row in
            self.shown(NSTextField.self, in: row).first { $0.stringValue == "Team Relay" }.map {
                $0.alignmentRect(forFrame: $0.frame).minX
            } ?? -1
        }
        XCTAssertEqual(title(bare), 10)
        XCTAssertEqual(title(marked), 10 + 28 + 10)
    }

    func testTheClaudeMarkIsThePackagesOwn() {
        XCTAssertGreaterThan(NSImage.claudeMark.size.width, 0)
    }

    // MARK: - Add Provider…

    func testAddProviderAddsAndImportsOnlyWhileThereIsSomethingToImport() throws {
        let button = AddProviderButton()
        var added = 0
        var imported = 0
        button.onAdd = { added += 1 }
        button.onImport = { imported += 1 }
        button.performClick(nil)
        XCTAssertEqual(added, 1)

        let item = try XCTUnwrap(button.menu.items.first)
        XCTAssertFalse(button.validateMenuItem(item))
        button.isImportEnabled = { true }
        XCTAssertTrue(button.validateMenuItem(item))
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        XCTAssertEqual(imported, 1)
    }

    // MARK: - The variable list

    private final class Recorder: EnvironmentVariablesViewControllerDelegate {
        var events: [String] = []
        var values = ["127.0.0.1,localhost"]

        func environmentVariables(_ list: EnvironmentVariablesViewController, didToggleAt index: Int) {
            events.append("toggle \(index)")
        }
        func environmentVariables(_ list: EnvironmentVariablesViewController, didSetName name: String, at index: Int) {
            events.append("name \(index) \(name)")
        }
        func environmentVariables(_ list: EnvironmentVariablesViewController, didSetValue value: String, at index: Int)
        {
            events.append("value \(index) \(value)")
        }
        func environmentVariablesDidAdd(_ list: EnvironmentVariablesViewController) -> Int {
            events.append("add")
            return values.count
        }
        func environmentVariables(_ list: EnvironmentVariablesViewController, didRemoveAt index: Int) {
            events.append("remove \(index)")
        }
        func environmentVariables(_ list: EnvironmentVariablesViewController, valueAt index: Int) -> String {
            values[index]
        }
    }

    private func list(_ rows: [EnvironmentRow], delegate: Recorder) -> EnvironmentVariablesViewController {
        let list = EnvironmentVariablesViewController()
        list.delegate = delegate
        list.view.frame = NSRect(x: 0, y: 0, width: 480, height: EnvironmentVariablesViewController.height)
        list.configure(with: rows)
        list.view.layoutSubtreeIfNeeded()
        return list
    }

    private static let proxy = EnvironmentRow(
        isEnabled: true, name: "NO_PROXY", displayValue: "127.0.0.1,localhost", warning: nil)

    func testAnEmptyListSaysHowToAdd() {
        let recorder = Recorder()
        let empty = list([], delegate: recorder)
        XCTAssertTrue(
            shown(NSTextField.self, in: empty.view).contains {
                $0.stringValue.contains(String(localized: "No Variables", bundle: .module))
            })
        let filled = list([Self.proxy], delegate: recorder)
        XCTAssertFalse(
            shown(NSTextField.self, in: filled.view).contains {
                $0.stringValue.contains(String(localized: "No Variables", bundle: .module))
            })
    }

    func testRowsShowTheirNameAndValueAndCheckbox() throws {
        let rows = [
            Self.proxy,
            EnvironmentRow(isEnabled: false, name: "ENABLE_TOOL_SEARCH", displayValue: "false", warning: "Ignored."),
        ]
        let list = list(rows, delegate: Recorder())
        let table = try XCTUnwrap(shown(NSTableView.self, in: list.view).first)
        XCTAssertEqual(table.numberOfRows, 2)
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? EnvironmentVariableCellView)
        XCTAssertEqual(cell.nameField.stringValue, "ENABLE_TOOL_SEARCH")
        XCTAssertEqual(cell.valueField.stringValue, "false")
        XCTAssertEqual(cell.checkbox.state, .off)
    }

    /// design/settings' `.env .tr`: `30px 1.6fr 1fr 22px`. The rows span the
    /// whole scroll view — no scroller beside them, whatever the Mac's setting —
    /// and the name takes 1.6 of every 2.6 of what the checkbox and the
    /// warning leave.
    func testTheNameColumnTakesOneAndSixTenthsToTheValuesOne() throws {
        for width: CGFloat in [500, 650] {
            let list = EnvironmentVariablesViewController()
            list.delegate = Recorder()
            list.view.frame = NSRect(x: 0, y: 0, width: width, height: EnvironmentVariablesViewController.height)
            list.configure(
                with: (0..<12).map { EnvironmentRow(isEnabled: true, name: "N\($0)", displayValue: "v", warning: nil) })
            list.view.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(shown(NSScrollView.self, in: list.view).first)
            let table = try XCTUnwrap(scroll.documentView as? NSTableView)
            let cell = try XCTUnwrap(
                table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? EnvironmentVariableCellView)
            cell.layoutSubtreeIfNeeded()
            // Each field spans its column less 2 a side: (name + 4) = 1.6 × (value + 4).
            XCTAssertEqual(
                cell.nameField.frame.width + 4, 1.6 * (cell.valueField.frame.width + 4), accuracy: 3)
        }
    }

    func testPlusAsksTheDelegateAndTheCheckboxReportsItsRow() throws {
        let recorder = Recorder()
        let list = list([Self.proxy], delegate: recorder)
        let add = try XCTUnwrap(shown(ListBarButton.self, in: list.view).first { $0.action == Selector(("add:")) })
        add.performClick(nil)
        XCTAssertEqual(recorder.events, ["add"])

        let table = try XCTUnwrap(shown(NSTableView.self, in: list.view).first)
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? EnvironmentVariableCellView)
        cell.checkbox.performClick(nil)
        XCTAssertEqual(recorder.events, ["add", "toggle 0"])
    }

    /// A field's ended edit reaches the delegate with its row; Escape on a row
    /// with neither a name nor a value removes it.
    func testAnEndedEditGoesToTheDelegateAndEscapeDropsABlankRow() throws {
        let recorder = Recorder()
        recorder.values.append("")
        let list = list(
            [Self.proxy, EnvironmentRow(isEnabled: true, name: "", displayValue: "", warning: nil)], delegate: recorder)
        let table = try XCTUnwrap(shown(NSTableView.self, in: list.view).first)
        let first = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? EnvironmentVariableCellView)
        first.nameField.stringValue = "ALL_PROXY"
        first.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: first.nameField))
        XCTAssertEqual(recorder.events, ["name 0 ALL_PROXY"])

        let blank = try XCTUnwrap(
            table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? EnvironmentVariableCellView)
        XCTAssertTrue(
            blank.control(
                blank.valueField, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(recorder.events, ["name 0 ALL_PROXY", "remove 1"])
    }

    func testMinusIsOffUntilARowIsSelected() throws {
        let list = list([Self.proxy], delegate: Recorder())
        let remove = try XCTUnwrap(
            shown(ListBarButton.self, in: list.view).first { $0.action == Selector(("remove:")) })
        XCTAssertFalse(remove.isEnabled)
        let table = try XCTUnwrap(shown(NSTableView.self, in: list.view).first)
        table.selectRowIndexes([0], byExtendingSelection: false)
        XCTAssertTrue(remove.isEnabled)
    }

    // MARK: - The sections

    private final class SectionRecorder: SubscriptionSectionViewControllerDelegate,
        ProvidersSectionViewControllerDelegate
    {
        var events: [String] = []

        func subscriptionSectionDidRequestOpen(_ section: SubscriptionSectionViewController) {
            events.append("open subscription")
        }
        func subscriptionSectionDidRequestSignIn(_ section: SubscriptionSectionViewController) {
            events.append("sign in")
        }
        func subscriptionSectionDidCancelSignIn(_ section: SubscriptionSectionViewController) {
            events.append("cancel sign in")
        }
        func subscriptionSectionDidRequestSignOut(_ section: SubscriptionSectionViewController) {
            events.append("sign out")
        }
        func providersSectionDidRequestAdd(_ section: ProvidersSectionViewController) {
            events.append("add")
        }
        func providersSectionDidRequestImport(_ section: ProvidersSectionViewController) {
            events.append("import")
        }
        func providersSectionCanImport(_ section: ProvidersSectionViewController) -> Bool { false }
        func providersSection(_ section: ProvidersSectionViewController, didOpen id: UUID) {
            events.append("open \(id)")
        }
        func providersSection(_ section: ProvidersSectionViewController, didRequestDuplicate id: UUID) {
            events.append("duplicate \(id)")
        }
        func providersSection(_ section: ProvidersSectionViewController, didRequestDelete id: UUID) {
            events.append("delete \(id)")
        }
    }

    private func laidOut(_ controller: NSViewController) -> NSView {
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        return controller.view
    }

    /// Sends a menu item's action as choosing it does.
    private func choose(_ title: String, in menu: NSMenu?) throws {
        let item = try XCTUnwrap(menu?.items.first { $0.title == title })
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
    }

    private static let signedIn = AccountRowContent(
        title: "name@example.com", subtitle: "Claude Max · Personal", mark: .claude, accessory: .info)

    func testSignedOutTheRowAsksToSignIn() throws {
        let recorder = SectionRecorder()
        let section = SubscriptionSectionViewController()
        section.delegate = recorder
        section.show(.signedOut)
        let view = laidOut(section)
        let button = try XCTUnwrap(shown(NSButton.self, in: view).first)
        XCTAssertEqual(button.title, String(localized: "Sign In…", bundle: .module))
        button.performClick(nil)
        XCTAssertEqual(recorder.events, ["sign in"])
        XCTAssertNil(try XCTUnwrap(shown(AccountRowView.self, in: view).first).menu)
    }

    func testSignedInTheRowOpensAndItsMenuSignsOut() throws {
        let recorder = SectionRecorder()
        let section = SubscriptionSectionViewController()
        section.delegate = recorder
        section.show(.signedIn(Self.signedIn))
        let view = laidOut(section)
        XCTAssertTrue(shown(NSTextField.self, in: view).contains { $0.stringValue == "name@example.com" })
        try XCTUnwrap(shown(NSButton.self, in: view).first).performClick(nil)
        let row = try XCTUnwrap(shown(AccountRowView.self, in: view).first)
        try choose(String(localized: "Details…", bundle: .module), in: row.menu)
        try choose(String(localized: "Sign Out…", bundle: .module), in: row.menu)
        XCTAssertEqual(recorder.events, ["open subscription", "open subscription", "sign out"])
    }

    func testCheckingShowsASpinnerAndOffersNothing() throws {
        let section = SubscriptionSectionViewController()
        section.show(.checking)
        let view = laidOut(section)
        XCTAssertEqual(shown(NSProgressIndicator.self, in: view).count, 1)
        XCTAssertTrue(shown(NSButton.self, in: view).isEmpty)
    }

    func testNoProvidersIsTheEmptyStateWithItsOwnAddButton() throws {
        let recorder = SectionRecorder()
        let section = ProvidersSectionViewController()
        section.delegate = recorder
        section.show([])
        let view = laidOut(section)
        XCTAssertEqual(shown(ProvidersEmptyView.self, in: view).count, 1)
        let adds = shown(AddProviderButton.self, in: view)
        XCTAssertEqual(adds.count, 1, "the button under the group hides while the empty state carries one")
        adds.first?.performClick(nil)
        XCTAssertEqual(recorder.events, ["add"])
    }

    func testEachProviderIsARowThatReportsItsID() throws {
        let recorder = SectionRecorder()
        let section = ProvidersSectionViewController()
        section.delegate = recorder
        let ids = [UUID(), UUID()]
        section.show(
            zip(ids, ["Local Proxy", "Team Relay"]).map { id, title in
                .init(id: id, content: AccountRowContent(title: title, subtitle: "", mark: .provider, accessory: .info))
            })
        let view = laidOut(section)
        let rows = shown(AccountRowView.self, in: view)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(shown(ProvidersEmptyView.self, in: view).isEmpty)
        XCTAssertEqual(shown(AddProviderButton.self, in: view).count, 1)

        try choose(String(localized: "Details…", bundle: .module), in: rows[1].menu)
        try choose(String(localized: "Duplicate", bundle: .module), in: rows[1].menu)
        try choose(String(localized: "Delete…", bundle: .module), in: rows[0].menu)
        XCTAssertEqual(recorder.events, ["open \(ids[1])", "duplicate \(ids[1])", "delete \(ids[0])"])
    }
}
