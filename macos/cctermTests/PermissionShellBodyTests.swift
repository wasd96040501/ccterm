import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// CI-gate measurement test (non-snapshot — runs on the unfiltered `make
/// test-unit`) for the AppKit `.bash` / `.powerShell` permission body
/// (`PermissionShellCardBodyView` + `PermissionShellCardBodyBuilder`, migration
/// plan §4.4, §9). Drives the REAL production body builder with representative
/// `PermissionRequest`s and asserts the parsed fields actually render into the
/// produced `NSView` tree — the command diff, the optional dim description, and
/// the optional compound-command hint — against the real surface (no stub, no
/// re-implemented approximation).
///
/// The body reuses the per-kind data getters VERBATIM by delegating to the
/// SwiftUI `PermissionShellCardBody`'s `internal` getters; these tests assert the
/// AppKit view's arranged subviews track those getters (presence/absence
/// gating + the rendered text), which is the observable parity contract.
@MainActor
final class PermissionShellBodyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Fixture helpers (real PermissionRequest via the SDK preview seam)

    private func request(toolName: String, input: [String: Any]) -> PermissionRequest {
        PermissionRequest.makePreview(
            requestId: "shell-\(UUID().uuidString)", toolName: toolName, input: input)
    }

    /// A request whose decision reason is `subcommandResults` with N Bash rules,
    /// so `compoundHint` resolves (the multi-rule path). Built through the real
    /// JSON init so the production `decisionReason` / `permissionSuggestions`
    /// parsing runs.
    private func compoundRequest(command: String, ruleCount: Int) -> PermissionRequest {
        let rules = (0..<ruleCount).map { i in
            ["tool_name": "Bash", "rule_content": "cmd\(i):*"]
        }
        let dict: [String: Any] = [
            "request_id": "shell-\(UUID().uuidString)",
            "tool_name": "Bash",
            "input": ["command": command],
            "decision_reason": ["type": "subcommandResults"],
            "permission_suggestions": [
                [
                    "type": "addRules",
                    "rules": rules,
                    "behavior": "allow",
                    "destination": "localSettings",
                ]
            ],
        ]
        return try! PermissionRequest(json: dict)
    }

    /// Mount the body in an offscreen window at a fixed width so the embedded
    /// `PermissionBoundedDiffView` typesets at a real settled width.
    @discardableResult
    private func mount(_ view: NSView, width: CGFloat = 480) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 700))
        window.contentView = container
        window.ccterm_orderFrontForTesting()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        return window
    }

    /// Walk the view tree for an `NSTextField` whose string equals `text`.
    private func containsLabel(_ root: NSView, withText text: String) -> Bool {
        if let field = root as? NSTextField, field.stringValue == text { return true }
        return root.subviews.contains { containsLabel($0, withText: text) }
    }

    // MARK: - Builder dispatch produces the real body view

    func testBuilderProducesShellBodyView() {
        // The real builder (the one `permissionCardBodyBuilder(for: .bash)`
        // returns post-integration) makes the production body view, not a bare
        // NSView stub.
        let req = request(toolName: "Bash", input: ["command": "ls -la"])
        let body = PermissionShellCardBodyBuilder().makeBody(request: req, engine: nil)
        XCTAssertTrue(
            body is PermissionShellCardBodyView,
            "The Shell builder produces the real PermissionShellCardBodyView.")
    }

    // MARK: - Command always renders as a diff (no nil-diff arm for Shell)

    func testCommandRendersAsDiffBlock() {
        let req = request(toolName: "Bash", input: ["command": "rm -rf node_modules"])
        let view = PermissionShellCardBodyView(request: req, kind: .bash, engine: nil)
        mount(view)
        view.layoutSubtreeIfNeeded()

        // The command diff is the first arranged subview and is ALWAYS present.
        XCTAssertTrue(
            view.arrangedSubviews.first === view.resolvedDiffView,
            "The command diff is the first arranged subview (always present).")
        // It carries the actual command (new-file mode, command verbatim) — the
        // real DiffBlock the embedded DiffNSView renders.
        let diff = view.resolvedDiffView.diff
        XCTAssertTrue(diff.isNewFile, "Command renders in new-file mode (no +/- chrome).")
        XCTAssertEqual(diff.newString, "rm -rf node_modules", "Command text rendered verbatim.")
    }

    func testEmptyCommandRendersEmDashDiff() {
        let req = request(toolName: "Bash", input: [:])
        let view = PermissionShellCardBodyView(request: req, kind: .bash, engine: nil)
        XCTAssertEqual(
            view.resolvedDiffView.diff.newString, "—",
            "A missing command renders as the em-dash placeholder (parity with SwiftUI).")
    }

    func testPowerShellUsesPs1SyntheticPath() {
        let req = request(toolName: "PowerShell", input: ["command": "Get-ChildItem"])
        let view = PermissionShellCardBodyView(request: req, kind: .powerShell, engine: nil)
        XCTAssertTrue(
            view.resolvedDiffView.diff.filePath.hasSuffix(".ps1"),
            "PowerShell commands key off the .ps1 synthetic path.")
    }

    // MARK: - Description gating + rendered text

    func testDescriptionRendersWhenPresent() {
        let req = request(
            toolName: "Bash", input: ["command": "ls", "description": "List files"])
        let view = PermissionShellCardBodyView(request: req, kind: .bash, engine: nil)
        mount(view)
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.resolvedDescription, "List files")
        XCTAssertNotNil(view.descriptionLabel, "A non-empty description renders a label.")
        XCTAssertEqual(view.descriptionLabel?.stringValue, "List files")
        XCTAssertTrue(
            containsLabel(view, withText: "List files"),
            "The description text is actually in the rendered view tree.")
        // Parity constants: size 11, secondary, max 2 lines.
        XCTAssertEqual(view.descriptionLabel?.maximumNumberOfLines, 2)
        XCTAssertEqual(view.descriptionLabel?.textColor, .secondaryLabelColor)
        XCTAssertEqual(view.descriptionLabel?.font?.pointSize, 11)
    }

    func testDescriptionAbsentWhenMissing() {
        let req = request(toolName: "Bash", input: ["command": "ls"])
        let view = PermissionShellCardBodyView(request: req, kind: .bash, engine: nil)
        mount(view)
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(view.resolvedDescription)
        XCTAssertNil(
            view.descriptionLabel, "No description ⇒ no description label is built.")
        // Only the diff is arranged.
        XCTAssertEqual(view.arrangedSubviews.count, 1, "Only the command diff is present.")
    }

    func testEmptyDescriptionIsNotRendered() {
        // SwiftUI guards `!description.isEmpty` (PermissionShellCardBody.swift:44);
        // an empty-string description must not produce a label.
        let req = request(toolName: "Bash", input: ["command": "ls", "description": ""])
        let view = PermissionShellCardBodyView(request: req, kind: .bash, engine: nil)
        mount(view)
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(
            view.descriptionLabel, "An empty description string renders no label.")
    }

    // MARK: - Compound-command hint gating + rendered count

    func testCompoundHintRendersWithRuleCount() {
        // Multi-rule subcommandResults → the hint resolves and renders, carrying
        // the rule count (3).
        let req = compoundRequest(command: "cd src && git status && npm test", ruleCount: 3)
        let view = PermissionShellCardBodyView(request: req, kind: .bash, engine: nil)
        mount(view)
        view.layoutSubtreeIfNeeded()

        let hint = view.resolvedCompoundHint
        XCTAssertNotNil(hint, "A multi-rule compound command resolves a hint.")
        XCTAssertTrue(hint?.contains("3") == true, "The hint reports the rule count. hint=\(hint ?? "nil")")
        XCTAssertNotNil(view.compoundHintRow, "The hint row is built and arranged.")
        XCTAssertTrue(
            containsLabel(view, withText: hint!),
            "The compound-hint text is actually in the rendered view tree.")
    }

    func testCompoundHintAbsentForPlainCommand() {
        // A plain (non-subcommandResults) request resolves no hint, so no row.
        let req = request(toolName: "Bash", input: ["command": "ls -la"])
        let view = PermissionShellCardBodyView(request: req, kind: .bash, engine: nil)
        mount(view)
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(view.resolvedCompoundHint)
        XCTAssertNil(view.compoundHintRow, "No compound signal ⇒ no hint row.")
    }

    func testCompoundHintAbsentForSingleRule() {
        // subcommandResults but only ONE bash rule ⇒ the hint is intentionally
        // suppressed (PermissionShellCardBody.swift:100-101).
        let req = compoundRequest(command: "cd src && npm test", ruleCount: 1)
        let view = PermissionShellCardBodyView(request: req, kind: .bash, engine: nil)
        mount(view)
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(view.resolvedCompoundHint, "A single rule suppresses the hint.")
        XCTAssertNil(view.compoundHintRow)
    }

    // MARK: - Full arrangement order (diff → description → hint)

    func testArrangedOrderIsDiffThenDescriptionThenHint() {
        // A request that resolves all three arms: a description AND a multi-rule
        // subcommandResults compound signal. Built through the real JSON init so
        // the production parsing runs.
        let withAll = try! PermissionRequest(json: [
            "request_id": "shell-\(UUID().uuidString)",
            "tool_name": "Bash",
            "input": ["command": "cd src && git status && npm test", "description": "Run CI"],
            "decision_reason": ["type": "subcommandResults"],
            "permission_suggestions": [
                [
                    "type": "addRules",
                    "rules": [
                        ["tool_name": "Bash", "rule_content": "git status:*"],
                        ["tool_name": "Bash", "rule_content": "npm test:*"],
                    ],
                    "behavior": "allow",
                    "destination": "localSettings",
                ]
            ],
        ])
        let view = PermissionShellCardBodyView(request: withAll, kind: .bash, engine: nil)
        mount(view)
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            view.arrangedSubviews.count, 3,
            "diff + description + hint are all arranged when all three resolve.")
        XCTAssertTrue(view.arrangedSubviews[0] === view.resolvedDiffView)
        XCTAssertTrue(view.arrangedSubviews[1] === view.descriptionLabel)
        XCTAssertTrue(view.arrangedSubviews[2] === view.compoundHintRow)
    }

    // MARK: - Body view publishes no intrinsic size (R1 — no window collapse)

    func testBodyViewPublishesNoIntrinsicMetric() {
        let req = request(toolName: "Bash", input: ["command": "ls"])
        let view = PermissionShellCardBodyView(request: req, kind: .bash, engine: nil)
        XCTAssertEqual(
            view.intrinsicContentSize.width, NSView.noIntrinsicMetric,
            "The body never leaks a min-width up to the full-pane card host (R1).")
        XCTAssertEqual(view.intrinsicContentSize.height, NSView.noIntrinsicMetric)
    }
}
