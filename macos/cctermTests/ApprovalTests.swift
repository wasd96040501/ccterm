import AgentSDK
import XCTest

@testable import ccterm

final class ApprovalTests: XCTestCase {
    private func waiting(
        _ name: String, _ input: String, reason: String? = "rm -rf needs approval: it deletes files."
    )
        -> ToolCall
    {
        let use = ToolUseBlock(id: "c1", name: name, input: MessageScript.json(input))
        return ToolCall(
            use: use, result: nil, kind: ToolKind(use, result: nil), state: .waiting(reason: reason), startedAt: nil,
            finishedAt: nil)
    }

    func testACommandIsItsDescriptionAndTheCommandWhole() {
        let approval = Approval(
            waiting("Bash", #"{"command":"rm -rf macos/build/test-dd","description":"Remove the build cache"}"#))
        XCTAssertEqual(approval.id, "c1")
        XCTAssertEqual(approval.tile, Tile(glyph: .tool(.command), state: .waiting))
        XCTAssertEqual(approval.title, "Remove the build cache")
        XCTAssertEqual(approval.body, .command("rm -rf macos/build/test-dd"))
        XCTAssertEqual(approval.reason, "rm -rf needs approval: it deletes files.")
        XCTAssertEqual(approval.request, "Claude wants to run this command")
    }

    func testACommandWithoutADescriptionSaysWhatItIs() {
        XCTAssertEqual(Approval(waiting("Bash", #"{"command":"ls"}"#, reason: nil)).title, "Run a command")
    }

    func testAnEditShowsTheLinesItTakesOutAndPutsIn() {
        let approval = Approval(
            waiting("Edit", #"{"file_path":"/r/A.swift","old_string":"a\nb","new_string":"c"}"#, reason: nil))
        XCTAssertEqual(approval.title, "Edit A.swift")
        XCTAssertEqual(approval.body, .change(removed: ["a", "b"], added: ["c"]))
        XCTAssertNil(approval.reason)
        XCTAssertEqual(approval.request, "Claude wants to make this edit")
    }

    func testAMultiEditShowsEveryEdit() {
        let approval = Approval(
            waiting(
                "MultiEdit",
                #"{"file_path":"/r/A.swift","edits":[{"old_string":"a","new_string":"b"},{"old_string":"c","new_string":"d"}]}"#
            ))
        XCTAssertEqual(approval.body, .change(removed: ["a", "c"], added: ["b", "d"]))
    }

    func testANewFileShowsItsContent() {
        let approval = Approval(waiting("Write", #"{"file_path":"/r/B.swift","content":"x\ny"}"#))
        XCTAssertEqual(approval.title, "Create B.swift")
        XCTAssertEqual(approval.body, .change(removed: [], added: ["x", "y"]))
        XCTAssertEqual(approval.request, "Claude wants to create this file")
    }

    func testAnyOtherToolIsNamed() {
        let approval = Approval(waiting("WebFetch", #"{"url":"https://example.com"}"#))
        XCTAssertEqual(approval.title, "Use WebFetch")
        XCTAssertNil(approval.body)
        XCTAssertEqual(approval.request, "Claude wants to use WebFetch")
    }
}
