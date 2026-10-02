import AgentSDK
import XCTest

@testable import ccterm

/// What each of the reader's answers tells the CLI, without AppKit.
final class DecisionPermissionTests: XCTestCase {

    private let gitStatus = PermissionRule(toolName: "Bash", ruleContent: "git status:*")
    private let gitDiff = PermissionRule(toolName: "Bash", ruleContent: "git diff:*")

    private func request(
        _ name: String = "Bash", input: String = #"{"command":"git status"}"#, suggestions: [PermissionUpdate] = []
    ) -> PermissionRequest {
        PermissionRequest(
            toolName: name, toolUseID: "c1", input: MessageScript.json(input), suggestions: suggestions,
            onRespond: { _ in })
    }

    func testAllowAndApprovePlanAllowWithoutChanges() {
        XCTAssertEqual(Decision.allow.permissionDecision(for: request()), .allow())
        XCTAssertEqual(Decision.approvePlan.permissionDecision(for: request("ExitPlanMode")), .allow())
    }

    func testDenyIsTheCLIsRejectionWordsAndDoesNotEndTheTurn() {
        guard case .deny(let message, let interrupt) = Decision.deny.permissionDecision(for: request()) else {
            return XCTFail("not a deny")
        }
        XCTAssertTrue(message.hasPrefix("The user doesn't want to proceed with this tool use"))
        XCTAssertFalse(interrupt)
    }

    func testKeepPlanningDeniesWithWordsTheModelReads() {
        XCTAssertEqual(
            Decision.keepPlanning.permissionDecision(for: request("ExitPlanMode")),
            .deny(message: "The user wants to keep planning."))
    }

    func testAlwaysAllowAppliesTheSuggestionCarryingTheRule() {
        let status = PermissionUpdate.addRules([gitStatus], behavior: .allow, destination: .localSettings)
        let diff = PermissionUpdate.addRules([gitDiff], behavior: .allow, destination: .localSettings)
        let decision = Decision.alwaysAllow(rule: "Bash(git diff:*)").permissionDecision(
            for: request(suggestions: [status, diff]))
        XCTAssertEqual(decision, .allow(updatedPermissions: [diff]))
    }

    func testAlwaysAllowWithAnUnknownRuleAppliesEverySuggestion() {
        let status = PermissionUpdate.addRules([gitStatus], behavior: .allow, destination: .localSettings)
        let mode = PermissionUpdate.setMode(.acceptEdits, destination: .session)
        let decision = Decision.alwaysAllow(rule: "Bash(ls:*)").permissionDecision(
            for: request(suggestions: [status, mode]))
        XCTAssertEqual(decision, .allow(updatedPermissions: [status, mode]))
    }

    func testAlwaysAllowWithNothingSuggestedIsAPlainAllow() {
        XCTAssertEqual(Decision.alwaysAllow(rule: "Bash").permissionDecision(for: request()), .allow())
    }

    func testAnswersJoinTheToolsInputUnderAnswers() {
        let input = #"{"questions":[{"question":"Which?","header":"H","options":[],"multiSelect":false}]}"#
        let decision = Decision.answer(["Which?": "A, B"]).permissionDecision(
            for: request("AskUserQuestion", input: input))
        guard case .allow(let updated?, let permissions) = decision else { return XCTFail("\(decision)") }
        XCTAssertTrue(permissions.isEmpty)
        XCTAssertEqual(updated["answers"], MessageScript.json(#"{"Which?":"A, B"}"#))
        XCTAssertEqual(updated["questions"]?.arrayValue?.count, 1)
    }
}
