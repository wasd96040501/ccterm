import AgentSDK
import XCTest

@testable import ccterm

/// Logic tests for the Task/Agent body's structured-input extraction:
/// `subagent_type`, `description`, `prompt`, `isolation`, `model`.
/// The chip row composition (Isolated worktree + model: X) is pinned
/// here so a future refactor can't silently drop a chip.
final class PermissionTaskAgentCardBodyTests: XCTestCase {

    func testSubagentTypeDrivesSubtitle() {
        let body = makeBody(input: [
            "subagent_type": "Explore",
            "prompt": "Find every callsite of foo()",
        ])
        XCTAssertEqual(body.subagentType, "Explore")
        let agentType = "Explore"
        XCTAssertEqual(body.subtitle, String(localized: "Run \(agentType) agent"))
    }

    func testSubagentTypeFallsBackToGenericSubTask() {
        // Upstream defaults `subagent_type` to `general-purpose` at
        // call time — but the field is omitted from `rawInput` when
        // the agent doesn't pick one. Surface "Run sub-task" so the
        // user isn't surprised by an empty headline.
        let body = makeBody(input: ["prompt": "do the thing"])
        XCTAssertNil(body.subagentType)
        XCTAssertEqual(body.subtitle, String(localized: "Run sub-task"))
    }

    func testCamelCaseSubagentTypeIsAccepted() {
        // Pre-v2 builds emit `subagentType` camelCase. Same shape.
        let body = makeBody(input: ["subagentType": "Plan"])
        XCTAssertEqual(body.subagentType, "Plan")
    }

    func testDescriptionAndPromptAreExposed() {
        let body = makeBody(input: [
            "subagent_type": "Plan",
            "description": "Design auth refactor",
            "prompt": "Sketch the migration plan",
        ])
        XCTAssertEqual(body.description, "Design auth refactor")
        XCTAssertEqual(body.prompt, "Sketch the migration plan")
    }

    func testEmptyStringFieldsTreatedAsNil() {
        // The fallback `String(localized:)` lookups should not see
        // empty strings — collapse them to nil at the data layer so
        // the view never renders a blank-but-present row.
        let body = makeBody(input: [
            "subagent_type": "",
            "description": "",
            "prompt": "",
            "isolation": "",
            "model": "",
        ])
        XCTAssertNil(body.subagentType)
        XCTAssertNil(body.description)
        XCTAssertNil(body.prompt)
        XCTAssertNil(body.isolation)
        XCTAssertNil(body.modelOverride)
        XCTAssertTrue(body.chips.isEmpty)
    }

    func testWorktreeIsolationProducesChip() {
        let body = makeBody(input: [
            "subagent_type": "Explore",
            "isolation": "worktree",
        ])
        XCTAssertEqual(body.chips, [String(localized: "Isolated worktree")])
    }

    func testUnknownIsolationFallsThroughAsLiteral() {
        // If a build introduces a new isolation mode (e.g. "remote")
        // we'd rather show the literal than silently drop it — the
        // user is making a trust decision either way.
        let body = makeBody(input: [
            "subagent_type": "Plan",
            "isolation": "remote",
        ])
        XCTAssertEqual(body.chips, ["remote"])
    }

    func testModelOverrideProducesChip() {
        let body = makeBody(input: [
            "subagent_type": "claude-code-guide",
            "model": "opus",
        ])
        let modelName = "opus"
        XCTAssertEqual(body.chips, [String(localized: "model: \(modelName)")])
    }

    func testWorktreeAndModelChipsAppearTogether() {
        let body = makeBody(input: [
            "subagent_type": "Explore",
            "isolation": "worktree",
            "model": "sonnet",
        ])
        let modelName = "sonnet"
        XCTAssertEqual(
            body.chips,
            [
                String(localized: "Isolated worktree"),
                String(localized: "model: \(modelName)"),
            ])
    }

    // MARK: - Helpers

    private func makeBody(input: [String: Any]) -> PermissionTaskAgentCardBody {
        let req = PermissionRequest.makePreview(
            requestId: "task-\(UUID().uuidString)",
            toolName: "Task",
            input: input)
        return PermissionTaskAgentCardBody(request: req)
    }
}
