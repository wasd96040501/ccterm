import AppKit
import DisplayModels
import XCTest

@testable import Components

/// The *Notes* a reader writes beside a previewed option travel with both
/// of the card's answers: Submit, and *Chat About This*.
@MainActor
final class QuestionRowViewNotesTests: XCTestCase {
    private final class Spy: PageRowViewDelegate {
        var decisions: [Decision] = []
        func pageRowView(_ rowView: NSView, didRequestDocument id: String, pinned: Bool) {}
        func pageRowView(_ rowView: NSView, didToggleDisclosureOf runID: String, inAllRuns all: Bool) {}
        func pageRowView(_ rowView: NSView, didRequestAllItemsOf runID: String) {}
        func pageRowView(_ rowView: NSView, didRequestOriginOf callID: String) {}
        func pageRowView(_ rowView: NSView, didDecide decision: Decision, forCall callID: String) {
            decisions.append(decision)
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func mount() -> (QuestionRowView, Spy, RowStage) {
        let view = QuestionRowView()
        let spy = Spy()
        view.delegate = spy
        view.configure(with: RowModels.layout(previews: true))
        return (view, spy, RowStage(view, size: CGSize(width: 520, height: 400)))
    }

    /// Pick *Split*, write notes, and press the button titled `title`.
    private func pickNoteAndPress(_ view: QuestionRowView, _ title: String) throws {
        let label = try XCTUnwrap(
            descendants(of: view).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Split" })
        let option = try XCTUnwrap(label.superview)
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1))
        option.mouseDown(with: event)
        let notes = try XCTUnwrap(
            descendants(of: view).compactMap { $0 as? NSTextField }.first { $0.tag == 1000 })
        notes.stringValue = "  keep the doc beside  "
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: notes))
        let button = try XCTUnwrap(
            descendants(of: view).compactMap { $0 as? NSButton }.first {
                $0.accessibilityLabel() == title || $0.attributedTitle.string == title
            })
        button.performClick(nil)
    }

    func testChatAboutThisCarriesTheAnswerAndTheNotes() throws {
        let (view, spy, stage) = mount()
        defer { stage.teardown() }
        try pickNoteAndPress(view, String(localized: "Chat About This", bundle: .module))
        XCTAssertEqual(
            spy.decisions,
            [.chatAbout(answers: ["Which layout?": "Split"], notes: ["Which layout?": "keep the doc beside"])])
    }

    func testSubmitCarriesTheNotes() throws {
        let (view, spy, stage) = mount()
        defer { stage.teardown() }
        try pickNoteAndPress(view, String(localized: "Submit", bundle: .module))
        XCTAssertEqual(
            spy.decisions,
            [.answer(["Which layout?": "Split"], notes: ["Which layout?": "keep the doc beside"])])
    }
}
