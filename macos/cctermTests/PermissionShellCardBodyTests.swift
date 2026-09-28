import AgentSDK
import XCTest

@testable import ccterm

/// Logic tests for the shell-command body's input-derived fields:
/// the visible command text, the optional description, and the
/// compound-command hint that surfaces when the CLI flagged the
/// request as `subcommandResults`. The view itself is rendered in
/// the snapshot suite — these tests pin the pure data extraction.
final class PermissionShellCardBodyTests: XCTestCase {

    func testCommandIsPulledFromRawInput() {
        let body = makeBody(toolName: "Bash", input: ["command": "ls -la"])
        XCTAssertEqual(body.command, "ls -la")
    }

    func testDescriptionIsPulledFromRawInput() {
        let body = makeBody(
            toolName: "Bash",
            input: ["command": "ls", "description": "List files"])
        XCTAssertEqual(body.description, "List files")
    }

    func testDescriptionIsNilWhenAbsent() {
        let body = makeBody(toolName: "Bash", input: ["command": "ls"])
        XCTAssertNil(body.description)
    }

    func testCompoundHintNilWithoutSubcommandResults() {
        // Plain decision reason → no compound hint, regardless of
        // how many bash rules the suggestion bundle carries.
        let req = makeRequest(
            toolName: "Bash",
            command: "ls",
            reason: "Tool requires user approval", reasonType: "rule",
            suggestions: [bashRule("ls:*"), bashRule("pwd:*")])
        let body = PermissionShellCardBody(request: req, kind: .bash)
        XCTAssertFalse(body.isCompoundCommand)
        XCTAssertNil(body.compoundHint)
    }

    func testCompoundHintNilWhenOnlyOneBashRule() {
        // Single bash rule reads as the editable-prefix path in
        // upstream; the hint is intentionally suppressed because
        // "Allow always" installs exactly one rule — no surprise.
        let req = makeRequest(
            toolName: "Bash",
            command: "cd src && npm test",
            reasonType: "subcommandResults",
            suggestions: [bashRule("npm test:*")])
        let body = PermissionShellCardBody(request: req, kind: .bash)
        XCTAssertTrue(body.isCompoundCommand)
        XCTAssertEqual(body.bashRuleCount, 1)
        XCTAssertNil(body.compoundHint)
    }

    func testCompoundHintShowsRuleCount() {
        // Multi-rule compound → hint reports the count so the user
        // knows "Allow always" will install several rules at once.
        let req = makeRequest(
            toolName: "Bash",
            command: "cd src && git status && npm test",
            reasonType: "subcommandResults",
            suggestions: [bashRule("git status:*"), bashRule("npm test:*"), bashRule("cd:*")])
        let body = PermissionShellCardBody(request: req, kind: .bash)
        XCTAssertEqual(body.bashRuleCount, 3)
        let hint = body.compoundHint
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("3") == true, "hint=\(hint ?? "nil")")
    }

    // MARK: - DiffBlock command rendering

    func testCommandDiffBlockIsNewFileMode() {
        // `isNewFile == true` makes DiffLayout render the body as a
        // code listing (gutter line numbers, no `+`/`-` sign column)
        // instead of "a diff that's all additions" — the right shape
        // for previewing a command before it runs.
        let body = makeBody(
            toolName: "Bash", input: ["command": "rm -rf node_modules"])
        let diff = body.commandDiffBlock
        XCTAssertTrue(diff.isNewFile)
        XCTAssertNil(diff.oldString)
        XCTAssertEqual(diff.newString, "rm -rf node_modules")
    }

    func testCommandDiffBlockUsesBashSyntheticPath() {
        // The diff body keys its syntax-highlight language off
        // `filePath`'s extension. Bash → `.sh` resolves to
        // highlight.js's `bash` lexer in `LanguageDetection`.
        let body = makeBody(toolName: "Bash", input: ["command": "echo hi"])
        let diff = body.commandDiffBlock
        XCTAssertEqual(LanguageDetection.language(for: diff.filePath), "bash")
    }

    func testCommandDiffBlockUsesPowerShellSyntheticPath() {
        // PowerShell has no entry in highlight.js's extToLang map, so
        // the language resolves to nil and the renderer skips coloring
        // — same shape as plain monospaced text, which is fine for
        // PowerShell today. The extension is still distinct so a
        // future highlighter for `.ps1` would slot in without code
        // changes here.
        let body = makeBody(
            toolName: "PowerShell", input: ["command": "Get-ChildItem"])
        let diff = body.commandDiffBlock
        XCTAssertTrue(diff.filePath.hasSuffix(".ps1"))
    }

    func testCommandDiffBlockPreservesMultilineHeredoc() {
        // The diff renderer paginates one line per row; the multi-line
        // command must arrive intact so the user sees every line.
        let heredoc = "git commit -m \"$(cat <<'EOF'\nfeat: x\n\nbody\nEOF\n)\""
        let body = makeBody(toolName: "Bash", input: ["command": .string(heredoc)])
        let diff = body.commandDiffBlock
        // Trailing newline (if any) is stripped to avoid a blank row.
        XCTAssertFalse(diff.newString.hasSuffix("\n"))
        XCTAssertTrue(diff.newString.contains("feat: x"))
        XCTAssertTrue(diff.newString.contains("EOF"))
    }

    func testCommandDiffBlockFallsBackToEmDashWhenCommandMissing() {
        let body = makeBody(toolName: "Bash", input: [:])
        XCTAssertEqual(body.commandDiffBlock.newString, "—")
    }

    func testCompoundHintCountsPowerShellRulesToo() {
        // The hint covers either shell — same UI surface.
        let req = makeRequest(
            toolName: "PowerShell",
            command: "Get-ChildItem; Get-Process",
            reasonType: "subcommandResults",
            suggestions: [
                powerShellRule("Get-ChildItem:*"),
                powerShellRule("Get-Process:*"),
            ])
        let body = PermissionShellCardBody(request: req, kind: .powerShell)
        XCTAssertEqual(body.bashRuleCount, 2)
        XCTAssertTrue(body.compoundHint?.contains("2") == true)
    }

    // MARK: - Helpers

    private func makeBody(toolName: String, input: JSONValue) -> PermissionShellCardBody {
        let req = PermissionRequest.preview(
            id: "shell-\(toolName)",
            toolName: toolName,
            input: input)
        return PermissionShellCardBody(
            request: req, kind: PermissionCardKind.kind(for: req))
    }

    /// `reasonType` is the CLI's `decision_reason_type`.
    private func makeRequest(
        toolName: String,
        command: String,
        reason: String? = nil,
        reasonType: String?,
        suggestions: [PermissionUpdate]
    ) -> PermissionRequest {
        PermissionRequest(
            id: "shell-\(UUID().uuidString)", toolName: toolName, input: ["command": .string(command)],
            suggestions: suggestions, decisionReason: reason, decisionReasonType: reasonType,
            onRespond: { _ in })
    }

    private func bashRule(_ content: String) -> PermissionUpdate {
        .addRules(
            [PermissionRule(toolName: "Bash", ruleContent: content)], behavior: .allow,
            destination: .localSettings)
    }

    private func powerShellRule(_ content: String) -> PermissionUpdate {
        .addRules(
            [PermissionRule(toolName: "PowerShell", ruleContent: content)], behavior: .allow,
            destination: .localSettings)
    }
}
