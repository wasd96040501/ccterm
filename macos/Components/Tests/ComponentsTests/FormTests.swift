import AppKit
import XCTest

@testable import Components

/// The Settings form's components, driven as their controls are and read off
/// what they show.
final class FormTests: XCTestCase {
    private func shown<V: NSView>(_ type: V.Type, in root: NSView, where match: (V) -> Bool) -> [V] {
        var found: [V] = []
        func walk(_ view: NSView) {
            if let view = view as? V, !view.isHiddenOrHasHiddenAncestor, match(view) { found.append(view) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    /// A description is a line of its own under the title: set, the row grows
    /// by it; cleared, the row is its title's line again.
    func testARowsDescriptionAddsALineAndClearingItTakesItAway() {
        let row = FormRowView(title: "Base URL", accessory: FormTextField(placeholder: "https://"))
        row.frame.size.width = 480
        let bare = row.fittingSize.height

        row.detail = "Requests go to api.anthropic.com."
        XCTAssertGreaterThan(row.fittingSize.height, bare + 8)

        row.detail = nil
        XCTAssertEqual(row.fittingSize.height, bare, accuracy: 0.5)
    }

    /// At rest the secret shows its mask, never its value; the eye shows the
    /// value in the clear and offers to hide it.
    func testTheSecretShowsItsMaskUntilTheEyeRevealsIt() throws {
        let field = FormSecretField(placeholder: "sk-ant-…")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 16)
        field.configure(value: "sk-ant-api03-abcdef", masked: "sk-ant-•••••cdef")

        XCTAssertFalse(shown(NSTextField.self, in: field) { $0.stringValue == "sk-ant-•••••cdef" }.isEmpty)
        XCTAssertTrue(
            shown(NSTextField.self, in: field) { !($0 is NSSecureTextField) && $0.stringValue == "sk-ant-api03-abcdef" }
                .isEmpty, "the value shows in the clear at rest")

        let eye = try XCTUnwrap(shown(NSButton.self, in: field) { _ in true }.first)
        eye.performClick(nil)

        XCTAssertFalse(
            shown(NSTextField.self, in: field) { !($0 is NSSecureTextField) && $0.stringValue == "sk-ant-api03-abcdef" }
                .isEmpty, "the eye did not reveal the value")
        // From the package's own catalogue, in whichever language runs the test.
        XCTAssertTrue(["Hide", "隐藏"].contains(eye.image?.accessibilityDescription ?? ""))
    }
}
