import AppKit
import DisplayModels
import XCTest

@testable import Components

/// The account sheet, shown a presentation and driven as its controls are:
/// what it shows for each kind, and what it reports.
final class AccountEditorTests: XCTestCase {
    private func shown<V: NSView>(_ type: V.Type, in root: NSView) -> [V] {
        var found: [V] = []
        func walk(_ view: NSView) {
            if let view = view as? V, !view.isHiddenOrHasHiddenAncestor { found.append(view) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    private func texts(in root: NSView) -> [String] {
        shown(NSTextField.self, in: root).map(\.stringValue)
    }

    private func button(_ title: String.LocalizationValue, in root: NSView) throws -> NSButton {
        let title = String(localized: title, bundle: .module)
        return try XCTUnwrap(shown(NSButton.self, in: root).first { $0.title == title }, title)
    }

    private func sheet(
        _ kind: AccountEditorViewController.Kind, _ presentation: AccountEditorPresentation
    )
        -> (AccountEditorViewController, Spy)
    {
        let sheet = AccountEditorViewController(kind: kind)
        let spy = Spy()
        sheet.delegate = spy
        sheet.show(presentation)
        sheet.view.frame = NSRect(origin: .zero, size: AccountEditorViewController.size)
        sheet.view.layoutSubtreeIfNeeded()
        return (sheet, spy)
    }

    private static func provider(
        _ authentication: AccountEditorPresentation.Authentication = .authToken, canSave: Bool = true
    ) -> AccountEditorPresentation {
        AccountEditorPresentation(
            canSave: canSave, baseURLError: nil, maskedCredential: "sk-••••••••7c1e", subscription: nil,
            fields: .init(
                name: "Local Proxy", baseURL: "http://127.0.0.1:8788", authentication: authentication,
                credential: "sk-proxy-example-4b0e9d2c7c1e", model: "claude-opus-5-5[1m]"),
            fieldsRevision: 0, environmentRows: [], commandDetail: .none)
    }

    func testAProvidersSheetShowsItsFieldsAndSavesOrDeletes() throws {
        let (sheet, _) = sheet(.provider, Self.provider())
        let values = shown(NSTextField.self, in: sheet.view).filter(\.isEditable).map(\.stringValue)
        XCTAssertTrue(values.contains("Local Proxy"))
        XCTAssertTrue(values.contains("http://127.0.0.1:8788"))
        XCTAssertTrue(values.contains("claude-opus-5-5[1m]"))
        XCTAssertTrue(texts(in: sheet.view).contains(String(localized: "Connection", bundle: .module)))
        XCTAssertNoThrow(try button("Save", in: sheet.view))
        XCTAssertNoThrow(try button("Delete…", in: sheet.view))
    }

    func testANewProviderAddsAndHasNothingToDelete() throws {
        let (sheet, _) = sheet(.newProvider, Self.provider(canSave: false))
        XCTAssertFalse(try button("Add", in: sheet.view).isEnabled)
        let delete = String(localized: "Delete…", bundle: .module)
        XCTAssertFalse(shown(NSButton.self, in: sheet.view).contains { $0.title == delete })
    }

    func testTheSubscriptionsSheetShowsItsAccountAndSignsOut() throws {
        var presentation = Self.provider()
        presentation.subscription = .init(email: "name@example.com", organization: "Personal", plan: "Claude Max")
        let (sheet, spy) = sheet(.subscription, presentation)
        let texts = texts(in: sheet.view)
        XCTAssertTrue(texts.contains("name@example.com"))
        XCTAssertTrue(texts.contains("Claude Max"))
        XCTAssertFalse(texts.contains(String(localized: "Connection", bundle: .module)))
        XCTAssertFalse(texts.contains(String(localized: "Models", bundle: .module)))
        try button("Sign Out…", in: sheet.view).performClick(nil)
        XCTAssertEqual(spy.events, ["removal"])
    }

    func testTheCredentialRowIsTitledByTheAuthentication() {
        let (sheet, _) = sheet(.provider, Self.provider(.authToken))
        XCTAssertTrue(texts(in: sheet.view).contains(String(localized: "Token", bundle: .module)))
        sheet.show(Self.provider(.apiKey))
        XCTAssertTrue(texts(in: sheet.view).contains(String(localized: "API key", bundle: .module)))
        XCTAssertFalse(texts(in: sheet.view).contains(String(localized: "Token", bundle: .module)))
    }

    func testTypingReportsTheFieldAndItsText() throws {
        let (sheet, spy) = sheet(.provider, Self.provider())
        let name = try XCTUnwrap(shown(NSTextField.self, in: sheet.view).first { $0.stringValue == "Local Proxy" })
        name.stringValue = "Relay"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: name)
        let model = try XCTUnwrap(
            shown(NSTextField.self, in: sheet.view).first { $0.stringValue == "claude-opus-5-5[1m]" })
        model.stringValue = "glm-5.2"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: model)
        XCTAssertEqual(spy.edits.map(\.field), [.name, .model(.main)])
        XCTAssertEqual(spy.edits.map(\.value), ["Relay", "glm-5.2"])
    }

    func testChoosingAnAuthenticationReportsIt() throws {
        let (sheet, spy) = sheet(.provider, Self.provider())
        let popUp = try XCTUnwrap(shown(FormPopUpButton.self, in: sheet.view).first)
        popUp.selectItem(at: 1)
        _ = popUp.target?.perform(popUp.action, with: popUp)
        XCTAssertEqual(spy.authentications, [.apiKey])
    }

    func testTheButtonsReportAndChangeNothing() throws {
        let (sheet, spy) = sheet(.provider, Self.provider())
        try button("Save", in: sheet.view).performClick(nil)
        try button("Cancel", in: sheet.view).performClick(nil)
        try button("Delete…", in: sheet.view).performClick(nil)
        XCTAssertEqual(spy.events, ["save", "cancel", "removal"])
    }

    /// Records what the sheet reports; the variable list's questions get
    /// plain answers.
    private final class Spy: AccountEditorViewControllerDelegate {
        var edits: [(field: AccountEditorViewController.Field, value: String)] = []
        var authentications: [AccountEditorPresentation.Authentication] = []
        var events: [String] = []

        func accountEditor(
            _ editor: AccountEditorViewController, didEdit field: AccountEditorViewController.Field, to value: String
        ) {
            edits.append((field, value))
        }

        func accountEditor(
            _ editor: AccountEditorViewController, didChoose authentication: AccountEditorPresentation.Authentication
        ) {
            authentications.append(authentication)
        }

        func accountEditor(_ editor: AccountEditorViewController, didPaste text: String) { events.append("paste") }
        func accountEditor(_ editor: AccountEditorViewController, didToggleVariableAt index: Int) {}
        func accountEditor(_ editor: AccountEditorViewController, didSetVariableName name: String, at index: Int) {}
        func accountEditor(_ editor: AccountEditorViewController, didSetVariableValue value: String, at index: Int) {}
        func accountEditorDidAddVariable(_ editor: AccountEditorViewController) -> Int { 0 }
        func accountEditor(_ editor: AccountEditorViewController, didRemoveVariableAt index: Int) {}
        func accountEditor(_ editor: AccountEditorViewController, valueOfVariableAt index: Int) -> String { "" }
        func accountEditorDidRequestManage(_ editor: AccountEditorViewController) { events.append("manage") }
        func accountEditorDidRequestSave(_ editor: AccountEditorViewController) { events.append("save") }
        func accountEditorDidCancel(_ editor: AccountEditorViewController) { events.append("cancel") }
        func accountEditorDidRequestRemoval(_ editor: AccountEditorViewController) { events.append("removal") }
    }
}
