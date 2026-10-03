import AppKit
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

    func testMinusIsOffUntilARowIsSelected() throws {
        let list = list([Self.proxy], delegate: Recorder())
        let remove = try XCTUnwrap(
            shown(ListBarButton.self, in: list.view).first { $0.action == Selector(("remove:")) })
        XCTAssertFalse(remove.isEnabled)
        let table = try XCTUnwrap(shown(NSTableView.self, in: list.view).first)
        table.selectRowIndexes([0], byExtendingSelection: false)
        XCTAssertTrue(remove.isEnabled)
    }
}
