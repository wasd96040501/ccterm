import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// CI-gate measurement test (non-snapshot) for the AppKit `.taskAgent` body —
/// `PermissionTaskAgentCardBodyView` (migration plan §4.4, §9). Drives the REAL
/// production body builder (`PermissionTaskAgentCardBodyBuilder.makeBody`)
/// with representative `PermissionRequest`s and asserts the parsed fields render
/// into the real view — never a re-implemented approximation, never the SwiftUI
/// data struct in isolation (the data layer is pinned separately by
/// `PermissionTaskAgentCardBodyTests`; THIS test pins the AppKit render).
@MainActor
final class PermissionTaskAgentBodyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    /// Build the body through the production dispatch conformer (NOT by calling
    /// the view initializer directly) so the test exercises the same surface the
    /// card mounts.
    private func makeBodyView(
        input: [String: Any], tool: String = "Task"
    )
        -> PermissionTaskAgentCardBodyView
    {
        let req = PermissionRequest.makePreview(
            requestId: "task-\(UUID().uuidString)", toolName: tool, input: input)
        let view = PermissionTaskAgentCardBodyBuilder()
            .makeBody(request: req, engine: nil)
        return try! XCTUnwrap(view as? PermissionTaskAgentCardBodyView)
    }

    /// Mount at a fixed settled width so the prompt block's used-height resolves
    /// (mirrors `PermissionMonospaceScrollViewTests.mounted`).
    @discardableResult
    private func mount(_ view: NSView, width: CGFloat = 480) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
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
        view.layoutSubtreeIfNeeded()
        addTeardownBlock {
            window.contentView = nil
            window.close()
        }
        return window
    }

    // MARK: - Headline (subagent_type → subtitle)

    func testSubagentTypeRendersAsSubtitle() {
        let view = makeBodyView(input: [
            "subagent_type": "Explore",
            "prompt": "Find every callsite of foo()",
        ])
        mount(view)
        let agentType = "Explore"
        XCTAssertEqual(
            view.renderedSubtitle, String(localized: "Run \(agentType) agent"),
            "Headline = the localized 'Run <type> agent' for the parsed subagent_type.")
        XCTAssertEqual(view.subtitleMaxLines, 1, "Subtitle is single-line (SwiftUI .lineLimit(1)).")
    }

    func testMissingSubagentTypeFallsBackToGenericSubTask() {
        let view = makeBodyView(input: ["prompt": "do the thing"])
        mount(view)
        XCTAssertEqual(
            view.renderedSubtitle, String(localized: "Run sub-task"),
            "No subagent_type → the localized generic 'Run sub-task' headline.")
    }

    // MARK: - Description (optional, 2-line clamp)

    func testDescriptionRendersWhenPresent() {
        let view = makeBodyView(input: [
            "subagent_type": "Plan",
            "description": "Design auth refactor",
            "prompt": "Sketch the migration plan",
        ])
        mount(view)
        XCTAssertEqual(
            view.renderedDescription, "Design auth refactor",
            "The description string renders below the headline.")
        XCTAssertEqual(
            view.descriptionMaxLines, 2,
            "Description clamps to 2 lines (SwiftUI .lineLimit(2)).")
    }

    func testDescriptionRowOmittedWhenAbsent() {
        let view = makeBodyView(input: ["subagent_type": "Explore", "prompt": "x"])
        mount(view)
        XCTAssertNil(
            view.renderedDescription,
            "No description field → the description row is omitted entirely (not blank-but-present).")
    }

    // MARK: - Chips (isolation + model override)

    func testWorktreeIsolationRendersChip() {
        let view = makeBodyView(input: [
            "subagent_type": "Explore",
            "isolation": "worktree",
        ])
        mount(view)
        XCTAssertEqual(
            view.renderedChipTexts, [String(localized: "Isolated worktree")],
            "isolation==worktree renders the localized 'Isolated worktree' chip.")
    }

    func testWorktreeAndModelChipsRenderTogetherInOrder() {
        let view = makeBodyView(input: [
            "subagent_type": "Explore",
            "isolation": "worktree",
            "model": "sonnet",
        ])
        mount(view)
        let modelName = "sonnet"
        XCTAssertEqual(
            view.renderedChipTexts,
            [
                String(localized: "Isolated worktree"),
                String(localized: "model: \(modelName)"),
            ],
            "Both chips render, isolation before the model override.")
    }

    func testNoChipsWhenNeitherIsolationNorModel() {
        let view = makeBodyView(input: ["subagent_type": "Plan", "prompt": "x"])
        mount(view)
        XCTAssertTrue(
            view.renderedChipTexts.isEmpty,
            "No isolation and no model override → no chip row.")
    }

    // MARK: - Prompt (200pt-cap monospace scroll)

    func testPromptRendersInBoundedScrollBlock() {
        let view = makeBodyView(input: [
            "subagent_type": "Explore",
            "prompt": "Locate every PermissionXxxCardBody and report its path.",
        ])
        mount(view)
        XCTAssertTrue(view.hasPromptBlock, "A non-empty prompt mounts the monospace scroll block.")
        let height = try! XCTUnwrap(view.promptResolvedHeight)
        XCTAssertGreaterThan(height, 0, "A short prompt resolves to a positive (intrinsic) height.")
        XCTAssertLessThanOrEqual(
            height, PermissionTaskAgentCardBodyView.promptScrollMaxHeight,
            "A short prompt stays at or below the 200pt cap.")
    }

    func testLongPromptCapsAt200() {
        let prompt = (0..<120).map { "step \($0): do a thing in the sub-task" }
            .joined(separator: "\n")
        let view = makeBodyView(input: ["subagent_type": "Plan", "prompt": prompt])
        mount(view)
        let height = try! XCTUnwrap(view.promptResolvedHeight)
        XCTAssertEqual(
            height, PermissionTaskAgentCardBodyView.promptScrollMaxHeight, accuracy: 0.5,
            "A long prompt clamps to exactly the 200pt cap so the decision buttons stay on-screen.")
    }

    func testPromptBlockOmittedWhenAbsent() {
        let view = makeBodyView(input: ["subagent_type": "Explore", "description": "summary only"])
        mount(view)
        XCTAssertFalse(view.hasPromptBlock, "No prompt field → no monospace scroll block.")
    }

    // MARK: - Empty-string fields collapse to omitted rows (parity with the data layer)

    func testEmptyStringFieldsRenderMinimalCard() {
        let view = makeBodyView(input: [
            "subagent_type": "",
            "description": "",
            "prompt": "",
            "isolation": "",
            "model": "",
        ])
        mount(view)
        // Empty subagent_type → generic headline; every optional row omitted.
        XCTAssertEqual(view.renderedSubtitle, String(localized: "Run sub-task"))
        XCTAssertNil(view.renderedDescription)
        XCTAssertTrue(view.renderedChipTexts.isEmpty)
        XCTAssertFalse(view.hasPromptBlock)
    }

    // MARK: - Sizing (no width leak — regime-B parity, plan R1)

    func testPublishesNoIntrinsicWidth() {
        let view = makeBodyView(input: ["subagent_type": "Explore", "prompt": "x"])
        XCTAssertEqual(
            view.intrinsicContentSize.width, NSView.noIntrinsicMetric,
            "The body publishes noIntrinsicMetric width so it can't leak a min-width to the host (R1).")
    }
}
