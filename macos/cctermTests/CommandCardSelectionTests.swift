import AppKit
import XCTest

@testable import ccterm

/// Clicking into a command's header to select text keeps its look: a
/// selectable field hands its text to the window's field editor on a click,
/// and the field editor sets it in the field's plain font unless the field
/// keeps its attributes.
@MainActor
final class CommandCardSelectionTests: XCTestCase {
    private var stage: AppKitStage?

    override func tearDown() {
        stage?.teardown()
        stage = nil
        super.tearDown()
    }

    func testSelectingTheCommandKeepsItsFonts() throws {
        let field = try mount(
            ToolCallFixture.bash("cd ~/dev/ccterm && make test-unit", description: "Run the unit tests", stdout: "ok"),
            fieldContaining: "make test-unit")
        let fonts = Self.fonts(in: field.attributedStringValue)
        XCTAssertTrue(fonts.allSatisfy(\.isFixedPitch), "premise: the command is monospaced: \(fonts)")
        try assertAClickKeepsTheAttributes(of: field)
    }

    func testSelectingThePersistedOutputsPathKeepsItsFonts() throws {
        let field = try mount(
            ToolCallFixture.bash("make logs", stdout: "…", persisted: "/tmp/ccterm/output.txt"),
            fieldContaining: "/tmp/ccterm/output.txt")
        let fonts = Self.fonts(in: field.attributedStringValue)
        XCTAssertTrue(fonts.contains(where: \.isFixedPitch), "premise: the path is monospaced: \(fonts)")
        try assertAClickKeepsTheAttributes(of: field)
    }

    /// The page above the output is views, not text: a double-click on the
    /// status line selects nothing of the page.
    func testADoubleClickOnTheStatusLineSelectsNothingOfThePage() throws {
        let call = ToolCallFixture.bash("make", description: "Build", stdout: "one\ntwo", duration: 2)
        let stage = AppKitStage.mount(CommandDocumentViewController(.call(call)), size: CGSize(width: 640, height: 420))
        self.stage = stage
        stage.drain()
        let status = try XCTUnwrap(
            stage.findAll(NSTextField.self).first { $0.stringValue == TimeInterval(2).durationText },
            "premise: the status line shows the time")
        let text = try XCTUnwrap(stage.find(NSTextView.self), "premise: the output is text")

        NumberedLinesViewTests.doubleClick(in: status, at: NSPoint(x: status.bounds.midX, y: status.bounds.midY))
        stage.drain()

        XCTAssertEqual(text.selectedRange().length, 0, "the double-click selected part of the page")
    }

    private func mount(_ call: ToolCall, fieldContaining text: String) throws -> NSTextField {
        let stage = AppKitStage.mount(CommandDocumentViewController(.call(call)), size: CGSize(width: 640, height: 420))
        self.stage = stage
        stage.drain()
        let fields = stage.findAll(NSTextField.self)
        return try XCTUnwrap(
            fields.first { $0.isSelectable && $0.stringValue.contains(text) },
            "premise: the field is on screen: \(fields.map(\.stringValue))")
    }

    private func assertAClickKeepsTheAttributes(
        of field: NSTextField, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let before = field.attributedStringValue
        // What a click on a selectable field does (the stage's window is never
        // key, so becoming first responder alone starts no editing): the cell
        // hands its text to the window's field editor.
        let window = try XCTUnwrap(field.window, file: file, line: line)
        let editor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView, file: file, line: line)
        field.cell?.select(withFrame: field.bounds, in: field, editor: editor, delegate: field, start: 0, length: 0)
        let shown = try XCTUnwrap(editor.textStorage, file: file, line: line)

        XCTAssertEqual(shown.string, before.string, file: file, line: line)
        XCTAssertEqual(
            Self.fonts(in: shown), Self.fonts(in: before), "the text changed font when clicked", file: file, line: line)
        XCTAssertTrue(
            before.isEqual(to: field.attributedStringValue), "the attributes were lost to the click", file: file,
            line: line)
    }

    private static func fonts(in text: NSAttributedString) -> [NSFont] {
        var fonts: [NSFont] = []
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let font = value as? NSFont { fonts.append(font) }
        }
        return fonts
    }
}
