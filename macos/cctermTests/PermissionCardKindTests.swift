import AgentSDK
import XCTest

@testable import ccterm

/// Verifies that `PermissionCardKind.kind(for:)` maps every
/// permission-bearing tool name the CLI can deliver onto the right
/// category, including the sed-in-Bash branch and the `mcp__*`
/// catch-all. Mirrors the upstream `permissionComponentForTool`
/// switch in `src/components/permissions/PermissionRequest.tsx` so a
/// future PR that adds a new tool category fails this test instead of
/// silently falling through to `.unknown`.
final class PermissionCardKindTests: XCTestCase {

    func testBashWithoutSedIsBash() {
        let req = makeRequest(toolName: "Bash", input: ["command": "ls -la"])
        XCTAssertEqual(PermissionCardKind.kind(for: req), .bash)
    }

    func testBashWithSedInPlaceEditIsSedEdit() {
        let req = makeRequest(
            toolName: "Bash",
            input: ["command": "sed -i 's/foo/bar/g' Sources/Greeter.swift"])
        XCTAssertEqual(PermissionCardKind.kind(for: req), .sedEdit)
    }

    func testBashWithSedDashIFlagFusedIsSedEdit() {
        // GNU / BSD both accept `sed -i.bak '…' file`. The fused flag
        // form must still classify as a sed edit.
        let req = makeRequest(
            toolName: "Bash",
            input: ["command": "sed -i.bak 's/foo/bar/' README.md"])
        XCTAssertEqual(PermissionCardKind.kind(for: req), .sedEdit)
    }

    func testBashWithSedButNoInPlaceFlagIsBash() {
        // `sed 's/x/y/' file` reads to stdout — not a file edit.
        let req = makeRequest(
            toolName: "Bash",
            input: ["command": "sed 's/x/y/' README.md | tee out.txt"])
        XCTAssertEqual(PermissionCardKind.kind(for: req), .bash)
    }

    func testPowerShellIsPowerShell() {
        let req = makeRequest(toolName: "PowerShell", input: ["command": "Get-ChildItem"])
        XCTAssertEqual(PermissionCardKind.kind(for: req), .powerShell)
    }

    func testFileEditFamilyMapsToFileEdit() {
        for name in ["Edit", "MultiEdit", "FileEdit"] {
            let req = makeRequest(toolName: name, input: [:])
            XCTAssertEqual(PermissionCardKind.kind(for: req), .fileEdit, "tool=\(name)")
        }
    }

    func testFileWriteFamilyMapsToFileWrite() {
        for name in ["Write", "FileWrite"] {
            let req = makeRequest(toolName: name, input: [:])
            XCTAssertEqual(PermissionCardKind.kind(for: req), .fileWrite, "tool=\(name)")
        }
    }

    func testNotebookEditIsNotebookEdit() {
        XCTAssertEqual(
            PermissionCardKind.kind(for: makeRequest(toolName: "NotebookEdit", input: [:])),
            .notebookEdit)
    }

    func testFilesystemReadFamilyMapsToFilesystemRead() {
        for name in ["Read", "Glob", "Grep", "FileRead"] {
            let req = makeRequest(toolName: name, input: [:])
            XCTAssertEqual(PermissionCardKind.kind(for: req), .filesystemRead, "tool=\(name)")
        }
    }

    func testWebFetchIsWebFetch() {
        XCTAssertEqual(
            PermissionCardKind.kind(for: makeRequest(toolName: "WebFetch", input: [:])),
            .webFetch)
    }

    func testEnterAndExitPlanModeAreSeparate() {
        XCTAssertEqual(
            PermissionCardKind.kind(for: makeRequest(toolName: "EnterPlanMode", input: [:])),
            .enterPlanMode)
        XCTAssertEqual(
            PermissionCardKind.kind(for: makeRequest(toolName: "ExitPlanMode", input: [:])),
            .exitPlanMode)
        // The CLI sometimes ships the v2 tool under a different name —
        // both must reach the same body renderer.
        XCTAssertEqual(
            PermissionCardKind.kind(for: makeRequest(toolName: "ExitPlanModeV2", input: [:])),
            .exitPlanMode)
    }

    func testTaskAndAgentMapToTaskAgent() {
        XCTAssertEqual(
            PermissionCardKind.kind(for: makeRequest(toolName: "Task", input: [:])),
            .taskAgent)
        XCTAssertEqual(
            PermissionCardKind.kind(for: makeRequest(toolName: "Agent", input: [:])),
            .taskAgent)
    }

    func testSkillIsSkill() {
        XCTAssertEqual(
            PermissionCardKind.kind(for: makeRequest(toolName: "Skill", input: [:])),
            .skill)
    }

    func testAskUserQuestionIsAskUserQuestion() {
        XCTAssertEqual(
            PermissionCardKind.kind(for: makeRequest(toolName: "AskUserQuestion", input: [:])),
            .askUserQuestion)
    }

    func testMcpPrefixedToolIsMcp() {
        for name in ["mcp__slack__send_message", "mcp__github__create_issue"] {
            XCTAssertEqual(
                PermissionCardKind.kind(for: makeRequest(toolName: name, input: [:])),
                .mcp,
                "tool=\(name)")
        }
    }

    func testEverythingElseFallsBackToUnknown() {
        for name in ["SomeNewTool", "Foo", "", "Bash2"] {
            XCTAssertEqual(
                PermissionCardKind.kind(for: makeRequest(toolName: name, input: [:])),
                .unknown,
                "tool=\(name)")
        }
    }

    // MARK: - Helpers

    private func makeRequest(toolName: String, input: [String: Any]) -> PermissionRequest {
        PermissionRequest.makePreview(
            requestId: "kind-\(toolName)",
            toolName: toolName,
            input: input)
    }
}
