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
            decisionReason: .string("Tool requires user approval"),
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
            decisionReason: .structured(type: "subcommandResults", reason: nil),
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
            decisionReason: .structured(type: "subcommandResults", reason: nil),
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
        let body = makeBody(toolName: "Bash", input: ["command": heredoc])
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
            decisionReason: .structured(type: "subcommandResults", reason: nil),
            suggestions: [
                powerShellRule("Get-ChildItem:*"),
                powerShellRule("Get-Process:*"),
            ])
        let body = PermissionShellCardBody(request: req, kind: .powerShell)
        XCTAssertEqual(body.bashRuleCount, 2)
        XCTAssertTrue(body.compoundHint?.contains("2") == true)
    }

    // MARK: - Helpers

    private func makeBody(toolName: String, input: [String: Any]) -> PermissionShellCardBody {
        let req = PermissionRequest.makePreview(
            requestId: "shell-\(toolName)",
            toolName: toolName,
            input: input)
        return PermissionShellCardBody(
            request: req, kind: PermissionCardKind.kind(for: req))
    }

    private func makeRequest(
        toolName: String,
        command: String,
        decisionReason: DecisionReason?,
        suggestions: [PermissionSuggestion]
    ) -> PermissionRequest {
        var dict: [String: Any] = [
            "request_id": "shell-\(UUID().uuidString)",
            "tool_name": toolName,
            "input": ["command": command],
            "permission_suggestions": suggestions.map { $0.toJSON() },
        ]
        switch decisionReason {
        case .string(let s)?:
            dict["decision_reason"] = ["type": "string", "reason": s]
        case .structured(let type, let reason)?:
            var dr: [String: Any] = ["type": type]
            if let reason { dr["reason"] = reason }
            dict["decision_reason"] = dr
        case nil:
            break
        }
        return try! PermissionRequest(json: dict)
    }

    private func bashRule(_ content: String) -> PermissionSuggestion {
        let json: [String: Any] = [
            "type": "addRules",
            "rules": [["tool_name": "Bash", "rule_content": content]],
            "behavior": "allow",
            "destination": "localSettings",
        ]
        return try! PermissionSuggestion(json: json)
    }

    private func powerShellRule(_ content: String) -> PermissionSuggestion {
        let json: [String: Any] = [
            "type": "addRules",
            "rules": [["tool_name": "PowerShell", "rule_content": content]],
            "behavior": "allow",
            "destination": "localSettings",
        ]
        return try! PermissionSuggestion(json: json)
    }
}
