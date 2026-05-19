import AgentSDK
import XCTest

@testable import ccterm

/// Logic tests for the v1 AskUserQuestion body. The full upstream
/// UI (multi-step, syntax-highlighted options, image paste) doesn't
/// fit the input-bar overlay surface — v1 is a summary card only.
/// Pin the summary derivation here: question count → headline,
/// first question text exposed, more-question hint when N > 1.
final class PermissionAskUserQuestionCardBodyTests: XCTestCase {

    func testSingleQuestionHeadline() {
        let body = makeBody(input: [
            "questions": [
                [
                    "question": "Which auth method should we use?",
                    "options": [["label": "OIDC"], ["label": "SAML"]],
                ]
            ]
        ])
        XCTAssertEqual(body.questionCount, 1)
        XCTAssertEqual(
            body.headline,
            String(localized: "Claude wants to ask you a question"))
        XCTAssertEqual(body.firstQuestion, "Which auth method should we use?")
    }

    func testMultipleQuestionHeadlineInterpolatesCount() {
        let body = makeBody(input: [
            "questions": [
                ["question": "Which library?"],
                ["question": "Which strategy?"],
                ["question": "Which fallback?"],
            ]
        ])
        XCTAssertEqual(body.questionCount, 3)
        let count = 3
        XCTAssertEqual(
            body.headline,
            String(localized: "Claude wants to ask you \(count) questions"))
        let remaining = 2
        XCTAssertEqual(
            body.remainingHint,
            String(localized: "\(remaining) more question(s) after this one"))
    }

    func testNoQuestionsFallsBackToSingularHeadline() {
        // Pathological — the agent shouldn't ship zero questions per
        // the upstream schema (min: 1), but never let the surface
        // crash on a bad payload.
        let body = makeBody(input: [:])
        XCTAssertEqual(body.questionCount, 0)
        XCTAssertNil(body.firstQuestion)
        XCTAssertEqual(
            body.headline,
            String(localized: "Claude wants to ask you a question"))
    }

    func testEmptyQuestionTextIsTreatedAsNil() {
        // Pin defensive nil-collapse — the view branches off this
        // value, an empty string would render an empty preview row.
        let body = makeBody(input: ["questions": [["question": ""]]])
        XCTAssertNil(body.firstQuestion)
    }

    // MARK: - Helpers

    private func makeBody(
        input: [String: Any]
    )
        -> PermissionAskUserQuestionCardBody
    {
        let req = PermissionRequest.makePreview(
            requestId: "ask-\(UUID().uuidString)",
            toolName: "AskUserQuestion",
            input: input)
        return PermissionAskUserQuestionCardBody(request: req)
    }
}
