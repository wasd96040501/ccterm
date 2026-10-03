import AppKit
import DisplayModels
import XCTest

@testable import Components

/// The bars over a document: the jump bar's button and the approval bar's
/// answers, driven as the document shell drives them.
@MainActor
final class DocumentBarsTests: XCTestCase {
    private func header(showsTranscriptJump: Bool = true) -> DocumentHeader {
        DocumentHeader(
            tile: Tile(glyph: .tool(.command), state: .done), crumbs: ["Run the unit tests"],
            title: "Run the unit tests", showsTranscriptJump: showsTranscriptJump)
    }

    func testTheJumpBarsButtonReportsToTheDelegate() {
        final class Recorder: JumpBarViewDelegate {
            var count = 0
            func jumpBarViewDidRequestShowInTranscript(_ jumpBar: JumpBarView) { count += 1 }
        }
        let bar = JumpBarView()
        let recorder = Recorder()
        bar.delegate = recorder
        bar.frame = NSRect(x: 0, y: 0, width: 400, height: JumpBarView.height)
        bar.configure(with: header())
        bar.layoutSubtreeIfNeeded()
        let button = bar.subviews.compactMap { $0 as? NSButton }.first
        button?.performClick(nil)
        XCTAssertEqual(recorder.count, 1)
    }

    func testTheJumpBarsButtonIsGoneWhereThereIsNoRowToGoBackTo() {
        let bar = JumpBarView()
        bar.frame = NSRect(x: 0, y: 0, width: 400, height: JumpBarView.height)
        bar.configure(with: header(showsTranscriptJump: false))
        bar.layoutSubtreeIfNeeded()
        let button = bar.subviews.compactMap { $0 as? NSButton }.first
        XCTAssertEqual(button?.isHidden, true)
        bar.configure(with: header())
        XCTAssertEqual(button?.isHidden, false)
    }

    func testTheApprovalBarsButtonsAnswerTheCallByItsID() {
        final class Recorder: ApprovalBarViewDelegate {
            var decisions: [(Decision, String)] = []
            func approvalBarView(_ approvalBar: ApprovalBarView, didDecide decision: Decision, forCall callID: String) {
                decisions.append((decision, callID))
            }
        }
        let bar = ApprovalBarView()
        let recorder = Recorder()
        bar.delegate = recorder
        bar.frame = NSRect(x: 0, y: 0, width: 640, height: 40)
        bar.configure(
            with: Approval(
                id: "c1", tile: Tile(glyph: .tool(.command), state: .waiting), title: "Run ls", body: .command("ls"),
                reason: nil, request: "Claude wants to run this command"))
        bar.layoutSubtreeIfNeeded()
        let buttons = bar.subviews.flatMap(\.subviews).compactMap { $0 as? NSButton }
        XCTAssertEqual(
            buttons.map(\.title),
            [String(localized: "Deny", bundle: .module), String(localized: "Allow", bundle: .module)])
        buttons.forEach { $0.performClick(nil) }
        XCTAssertEqual(recorder.decisions.map(\.0), [.deny, .allow])
        XCTAssertEqual(recorder.decisions.map(\.1), ["c1", "c1"])
        XCTAssertEqual(buttons[1].keyEquivalentModifierMask, .command)
    }
}
