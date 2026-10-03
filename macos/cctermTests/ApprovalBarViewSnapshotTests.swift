import AppKit
import DisplayModels
import XCTest

@testable import ccterm

/// The approval bar of a command and an edit, with a long reason and none, in
/// light and dark (02-command.md "Live"). Review only —
/// `make test-unit FILTER=ApprovalBarViewSnapshotTests`, then open
/// `/tmp/ccterm-screenshots/ApprovalBarView.png`.
@MainActor
final class ApprovalBarViewSnapshotTests: XCTestCase {
    private func waiting(_ name: String, _ input: String, reason: String?) -> Approval {
        Approval(ToolCallFixture.call(name, input, state: .waiting(reason: reason), hasResult: false))
    }

    private func controller(_ approval: Approval, width: CGFloat) -> NSViewController {
        let bar = ApprovalBarView()
        bar.configure(with: approval)
        bar.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 40))
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        let controller = NSViewController()
        controller.view = container
        return controller
    }

    func testTheBarInEachCase() {
        let states: [(Approval, CGFloat)] = [
            (
                waiting(
                    "Bash", #"{"command":"rm -rf x","description":"Remove the build cache"}"#,
                    reason: "rm -rf needs approval: it deletes files."), 640
            ),
            (
                waiting(
                    "Bash", #"{"command":"rm -rf x"}"#,
                    reason: "This command writes outside the working directory, so it needs approval before it runs."),
                520
            ),
            (waiting("Edit", #"{"file_path":"/r/A.swift","old_string":"a","new_string":"b"}"#, reason: nil), 640),
        ]
        let sheets = states.map { approval, width in
            ViewSnapshot.renderLightAndDark(
                { self.controller(approval, width: width) }, size: CGSize(width: width, height: 40), name: "")
        }
        let url = ViewSnapshot.writeStack(sheets, name: "ApprovalBarView")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTheButtonsAnswerTheCallByItsID() {
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
        bar.configure(with: waiting("Bash", #"{"command":"ls"}"#, reason: nil))
        bar.layoutSubtreeIfNeeded()
        let buttons = bar.subviews.flatMap(\.subviews).compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.map(\.title), [String(localized: "Deny"), String(localized: "Allow")])
        buttons.forEach { $0.performClick(nil) }
        XCTAssertEqual(recorder.decisions.map(\.0), [.deny, .allow])
        XCTAssertEqual(recorder.decisions.map(\.1), ["c1", "c1"])
        XCTAssertEqual(buttons[1].keyEquivalentModifierMask, .command)
    }
}
