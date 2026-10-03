import AgentSDK
import AppKit
import Components
import DisplayModels
import XCTest

@testable import ccterm

/// The approval card for a command, an edit, a long body and a bare tool,
/// light and dark (design/transcript/01-run.md "Waiting for you"). Review
/// only — `make test-unit FILTER=ApprovalCardViewSnapshotTests`, then open
/// `/tmp/ccterm-screenshots/ApprovalCardView.png`.
@MainActor
final class ApprovalCardViewSnapshotTests: XCTestCase {
    private func waiting(_ name: String, _ input: String, reason: String?) -> Approval {
        let use = ToolUseBlock(id: "c1", name: name, input: MessageScript.json(input))
        return Approval(
            ToolCall(
                use: use, result: nil, kind: ToolKind(use, result: nil), state: .waiting(reason: reason),
                startedAt: nil, finishedAt: nil))
    }

    private var many: String {
        (1...30).map { "let line\($0) = \($0)" }.joined(separator: "\\n")
    }

    private var approvals: [Approval] {
        [
            waiting(
                "Bash",
                #"{"command":"make test-unit FILTER=TranscriptViewTests","description":"Run the unit tests"}"#,
                reason: "Needs approval: writes outside the project (build/test-dd)"),
            waiting(
                "Edit",
                #"{"file_path":"/r/TranscriptView.swift","old_string":"var rowSpacing = 14\nvar other = 1","new_string":"public var rowSpacing: CGFloat = 14 {\n    didSet { apply() }\n}"}"#,
                reason: nil),
            waiting(
                "Bash",
                #"{"command":"swift build -c debug --product ccterm && swift build -c release --product ccterm && make test-unit FILTER=TranscriptViewTests && make test-kit && make test-sdk && echo done","description":"Build everything"}"#,
                reason: nil),
            waiting("Write", #"{"file_path":"/r/B.swift","content":"\#(many)"}"#, reason: "Needs approval: a new file"),
            waiting("WebFetch", #"{"url":"https://example.com"}"#, reason: nil),
        ]
    }

    func testEveryShape() {
        RowSnapshot.render(ApprovalCardView.self, approvals, gap: 8, name: "ApprovalCardView", test: self)
    }

    func testNarrow() {
        RowSnapshot.render(
            ApprovalCardView.self, approvals, widths: [320], gap: 8, name: "ApprovalCardViewNarrow", test: self)
    }
}
