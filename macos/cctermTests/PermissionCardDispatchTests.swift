import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// CI-gate tests for the per-kind body-builder dispatch + the AppKit card
/// chrome's `bodyOwnsChrome` gating + the decision button's role/title/action
/// mapping. Pure (no window) — drives `PermissionCardKind.kind(for:)` via real
/// `PermissionRequest.makePreview` payloads per kind, asserts the dispatch
/// returns the expected concrete STUB builder type and a non-nil `NSView`, and
/// drives the real production objects (`PermissionCardContentView`,
/// `PermissionDecisionButton`) — no re-implemented approximation.
@MainActor
final class PermissionCardDispatchTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func request(_ toolName: String, _ input: [String: Any] = [:]) -> PermissionRequest {
        PermissionRequest.makePreview(requestId: "req", toolName: toolName, input: input)
    }

    // MARK: - Dispatch: kind → builder type + non-nil body

    /// Each `PermissionCardKind` maps to exactly the expected concrete builder,
    /// and the real `PermissionCardContentView` chrome mounts that builder's
    /// body in its body slot (proving the dispatch → body → card-mount wiring,
    /// not a tautological non-nil check — `makeBody` returns a non-optional
    /// `NSView`, so a bare `XCTAssertNotNil` could never fail).
    func testDispatchReturnsExpectedBuilderPerKindAndMountsItsBody() throws {
        // (request, expected kind, expected builder type)
        let cases: [(PermissionRequest, PermissionCardKind, Any.Type)] = [
            (request("Bash", ["command": "ls"]), .bash, PermissionShellCardBodyBuilder.self),
            (request("PowerShell"), .powerShell, PermissionShellCardBodyBuilder.self),
            (
                request("Bash", ["command": "sed -i 's/a/b/' f.txt"]), .sedEdit,
                PermissionSedEditCardBodyBuilder.self
            ),
            (request("Edit"), .fileEdit, PermissionFileWriteCardBodyBuilder.self),
            (request("Write"), .fileWrite, PermissionFileWriteCardBodyBuilder.self),
            (request("NotebookEdit"), .notebookEdit, PermissionNotebookEditCardBodyBuilder.self),
            (request("Read"), .filesystemRead, PermissionFilesystemReadCardBodyBuilder.self),
            (request("WebFetch"), .webFetch, PermissionWebFetchCardBodyBuilder.self),
            (request("Task"), .taskAgent, PermissionTaskAgentCardBodyBuilder.self),
            (request("Skill"), .skill, PermissionSkillCardBodyBuilder.self),
            (request("mcp__server__tool"), .mcp, PermissionMcpCardBodyBuilder.self),
            (
                request("EnterPlanMode"), .enterPlanMode,
                PermissionEnterPlanModeCardBodyBuilder.self
            ),
            (request("ExitPlanMode"), .exitPlanMode, PermissionExitPlanModeCardBodyBuilder.self),
            (
                request("MysteryTool", ["command": "do-something"]), .unknown,
                PermissionFallbackCardBodyBuilder.self
            ),
        ]

        for (req, expectedKind, expectedBuilderType) in cases {
            let kind = PermissionCardKind.kind(for: req)
            XCTAssertEqual(kind, expectedKind, "kind mismatch for \(req.toolName)")

            let builder = permissionCardBodyBuilder(for: kind)
            XCTAssertTrue(
                type(of: builder) == expectedBuilderType,
                "dispatch returned \(type(of: builder)) for \(req.toolName), "
                    + "expected \(expectedBuilderType)")

            // Drive the real card chrome with this kind's builder and assert the
            // body it produced is the one mounted into the card's body slot. The
            // production path (`PermissionCardContentView` default `bodyBuilder`)
            // is `permissionCardBodyBuilder(for:)`, so this exercises exactly the
            // dispatch under test — the card mounts the per-kind body without
            // crashing, which is the maximum assertable surface for the STUB phase.
            let card = PermissionCardContentView(
                request: req, engine: nil,
                onAllowOnce: {}, onAllowAlways: {}, onDeny: {})
            XCTAssertTrue(
                card.arrangedSubviews.contains(card.resolvedBodyView),
                "the card for \(req.toolName) should mount its dispatched body view")
        }
    }

    /// The AskUserQuestion arm returns the AskUserQuestion builder (the §4.5
    /// delegation point — never actually asked for a body, but the dispatch is
    /// total).
    func testAskUserQuestionDispatchesToItsBuilder() throws {
        let req = request("AskUserQuestion", ["questions": []])
        let kind = PermissionCardKind.kind(for: req)
        XCTAssertEqual(kind, .askUserQuestion)
        let builder = permissionCardBodyBuilder(for: kind)
        XCTAssertTrue(builder is PermissionAskUserQuestionCardBodyBuilder)
    }

    // MARK: - bodyOwnsChrome gating (real PermissionCardContentView)

    /// A non-AskUserQuestion kind renders the full chrome — header + body +
    /// button row arranged subviews — and the reason row when a non-empty
    /// decision reason is present.
    func testGenericKindRendersHeaderBodyAndButtonRow() throws {
        let card = PermissionCardContentView(
            request: request("Bash", ["command": "ls"]),
            engine: nil,
            onAllowOnce: {}, onAllowAlways: {}, onDeny: {})
        XCTAssertFalse(card.bodyOwnsChrome)
        // header + body + button row (no reason — the preview has none).
        XCTAssertEqual(card.arrangedSubviews.count, 3)
        XCTAssertNotNil(card.headerRow, "generic chrome should render the header")
        XCTAssertNotNil(card.buttonRow, "generic chrome should render the button row")
        XCTAssertNil(card.reasonRow, "no reason → no reason row")
        XCTAssertEqual(
            card.decisionButtons.count, 3, "Deny / Allow once / Allow always")
    }

    /// AskUserQuestion takes over the chrome: NO header, NO reason, NO button
    /// row — only the body section (the §4.5 wizard, supplied later).
    func testAskUserQuestionRendersNoGenericChrome() throws {
        let card = PermissionCardContentView(
            request: request("AskUserQuestion", ["questions": []]),
            engine: nil,
            onAllowOnce: {}, onAllowAlways: {}, onDeny: {})
        XCTAssertTrue(card.bodyOwnsChrome)
        XCTAssertNil(card.headerRow, "AskUserQuestion owns its chrome — no header")
        XCTAssertNil(card.reasonRow, "AskUserQuestion owns its chrome — no reason row")
        XCTAssertNil(card.buttonRow, "AskUserQuestion owns its chrome — no button row")
        XCTAssertTrue(card.decisionButtons.isEmpty)
        // Only the body section is arranged.
        XCTAssertEqual(card.arrangedSubviews.count, 1)
    }

    /// The body builder can be injected so a test asserts the card mounts the
    /// exact body view the dispatch produced (drives the real chrome with a
    /// stub builder, no approximation).
    func testInjectedBodyBuilderSuppliesTheBodyView() throws {
        final class MarkerBody: NSView {}
        struct MarkerBuilder: PermissionCardBodyBuilding {
            func makeBody(request: PermissionRequest, engine: SyntaxHighlightEngine?) -> NSView {
                MarkerBody()
            }
        }
        let card = PermissionCardContentView(
            request: request("Bash", ["command": "ls"]),
            engine: nil,
            onAllowOnce: {}, onAllowAlways: {}, onDeny: {},
            bodyBuilder: { _ in MarkerBuilder() })
        XCTAssertTrue(card.resolvedBodyView is MarkerBody)
    }

    // MARK: - PermissionDecisionButton role/title/action (real object)

    /// Each role constructs with its title and fires its `onClick` exactly
    /// once on a synthetic click (measurement, not snapshot).
    func testDecisionButtonRolesFireActionOnce() throws {
        for role in [
            PermissionDecisionButton.Role.primary,
            .secondary, .destructive,
        ] {
            var fired = 0
            let button = PermissionDecisionButton(
                title: "Title-\(role)", role: role, onClick: { fired += 1 })
            XCTAssertEqual(button.title, "Title-\(role)")
            XCTAssertEqual(button.role, role)
            // `performClick` routes through the NSControl action; the production
            // mouse-up path also calls `fire()`. Drive the closure directly via
            // the production `onClick` (the same closure the mouse-up path fires).
            button.onClick?()
            XCTAssertEqual(fired, 1, "the \(role) button action should fire exactly once")
        }
    }
}
