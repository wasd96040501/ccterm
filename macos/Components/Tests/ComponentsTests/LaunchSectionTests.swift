import AppKit
import DisplayModels
import XCTest

@testable import Components

/// General's Claude Code section, shown states and driven as its controls
/// are: what each row's description line says, and what it reports.
final class LaunchSectionTests: XCTestCase {
    private var section: LaunchSectionViewController!
    private var spy: Spy!
    private var commandField: FormTextField!
    private var folderField: FormTextField!

    override func setUpWithError() throws {
        section = LaunchSectionViewController()
        spy = Spy()
        section.delegate = spy
        section.show(Self.state())
        section.view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        section.view.layoutSubtreeIfNeeded()
        let fields = shown(FormTextField.self, in: section.view)
        XCTAssertEqual(fields.count, 2)
        commandField = try XCTUnwrap(fields.first)
        folderField = try XCTUnwrap(fields.last)
    }

    private func shown<V: NSView>(_ type: V.Type, in root: NSView) -> [V] {
        var found: [V] = []
        func walk(_ view: NSView) {
            if let view = view as? V, !view.isHiddenOrHasHiddenAncestor { found.append(view) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    private static let found = ValidationDetail(text: "Claude Code 2.1.284", isError: false)

    private static func state(
        command: String = "", commandDetail: ValidationDetail = found, reason: ValidationDetail = found,
        fallback: String? = nil, revision: Int = 0
    ) -> LaunchSectionViewController.State {
        .init(
            command: .init(
                text: command, placeholder: "~/.local/bin/claude", detail: commandDetail, reason: reason,
                fallback: fallback),
            folder: .init(text: "", placeholder: "~/.claude", detail: .none, reason: .none, fallback: nil),
            allowsBypassPermissions: false, textsRevision: revision)
    }

    private func row(of field: NSView) throws -> FormRowView {
        var view: NSView? = field
        while let next = view, !(next is FormRowView) { view = next.superview }
        return try XCTUnwrap(view as? FormRowView)
    }

    func testItShowsTheTextsPlaceholdersAndWhatTheCheckFound() throws {
        XCTAssertEqual(commandField.placeholderString, "~/.local/bin/claude")
        XCTAssertEqual(folderField.placeholderString, "~/.claude")
        XCTAssertEqual(try row(of: commandField).detail, "Claude Code 2.1.284")
        XCTAssertFalse(try row(of: commandField).isDetailError)
        XCTAssertNil(try row(of: folderField).detail)
    }

    /// The texts only when their revision moves, so a field being typed in
    /// keeps its caret.
    func testTextsAreWrittenOnlyWhenTheirRevisionChanges() {
        commandField.stringValue = "orang"
        section.show(Self.state(command: "orange"))
        XCTAssertEqual(commandField.stringValue, "orang")
        section.show(Self.state(command: "orange", revision: 1))
        XCTAssertEqual(commandField.stringValue, "orange")
    }

    /// The reason in red, what stays in use after it in the secondary ink
    /// and the monospaced face.
    func testAProblemIsRedForItsReasonAndNamesWhatStaysInUse() throws {
        let reason = ValidationDetail.problem("Not found", fallback: nil)
        let detail = ValidationDetail.problem("Not found", fallback: "~/.local/bin/claude")
        section.show(Self.state(command: "bad", commandDetail: detail, reason: reason, fallback: "~/.local/bin/claude"))
        let row = try row(of: commandField)
        XCTAssertTrue(row.isDetailError)
        XCTAssertEqual(row.detailErrorLength, (reason.text! as NSString).length)
        let shown = try XCTUnwrap(row.attributedDetail)
        let path = (shown.string as NSString).range(of: "~/.local/bin/claude", options: .backwards)
        let font = try XCTUnwrap(shown.attribute(.font, at: path.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    func testTypingReturnAndLeavingAreReported() {
        commandField.stringValue = "orange"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: commandField)
        commandField.sendAction(commandField.action, to: commandField.target)
        folderField.stringValue = "~/work"
        folderField.delegate?.controlTextDidEndEditing?(
            Notification(name: NSControl.textDidEndEditingNotification, object: folderField))
        XCTAssertEqual(spy.events, ["edit command orange", "commit command orange", "commit folder ~/work"])
    }

    func testTheCheckboxFollowsTheStateAndReportsAClick() throws {
        let label = String(localized: "Allow Bypass Permissions", bundle: .module)
        let checkbox = try XCTUnwrap(shown(NSButton.self, in: section.view).first { $0.accessibilityLabel() == label })
        XCTAssertEqual(checkbox.state, .off)
        var on = Self.state()
        on.allowsBypassPermissions = true
        section.show(on)
        XCTAssertEqual(checkbox.state, .on)
        checkbox.performClick(nil)
        XCTAssertEqual(spy.events, ["bypass false"])
    }

    private final class Spy: LaunchSectionViewControllerDelegate {
        var events: [String] = []

        func launchSection(
            _ section: LaunchSectionViewController, didEdit field: LaunchSectionViewController.Field, text: String
        ) {
            events.append("edit \(field) \(text)")
        }

        func launchSection(
            _ section: LaunchSectionViewController, didCommit field: LaunchSectionViewController.Field, text: String
        ) {
            events.append("commit \(field) \(text)")
        }

        func launchSection(_ section: LaunchSectionViewController, didSetAllowsBypassPermissions allows: Bool) {
            events.append("bypass \(allows)")
        }
    }
}
