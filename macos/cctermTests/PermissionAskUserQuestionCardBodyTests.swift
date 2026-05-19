import AgentSDK
import XCTest

@testable import ccterm

/// Logic tests for the AskUserQuestion permission card. The view
/// itself is interactive (option vstack + Other input + per-question
/// progression) — these tests exercise the payload decoder so
/// malformed CLI inputs don't reach the view as half-formed data.
final class PermissionAskUserQuestionCardBodyTests: XCTestCase {

    func testParsesSingleQuestionWithOptions() throws {
        let raw =
            [
                "question": "Which auth method should we use?",
                "options": [["label": "OIDC"], ["label": "SAML"]],
            ] as [String: Any]
        let q = try XCTUnwrap(PermissionAskUserQuestionCardBody.Question(raw: raw))
        XCTAssertEqual(q.question, "Which auth method should we use?")
        XCTAssertEqual(q.multiSelect, false)
        XCTAssertNil(q.header)
        XCTAssertEqual(q.options.map(\.label), ["OIDC", "SAML"])
    }

    func testParsesHeaderAndMultiSelect() throws {
        let raw =
            [
                "question": "Which features should we enable?",
                "header": "Features",
                "multiSelect": true,
                "options": [
                    ["label": "Diff view", "description": "Side-by-side patches"],
                    ["label": "Inline highlight"],
                ],
            ] as [String: Any]
        let q = try XCTUnwrap(PermissionAskUserQuestionCardBody.Question(raw: raw))
        XCTAssertEqual(q.header, "Features")
        XCTAssertTrue(q.multiSelect)
        XCTAssertEqual(q.options.count, 2)
        XCTAssertEqual(q.options[0].description, "Side-by-side patches")
        XCTAssertNil(q.options[1].description)
    }

    func testEmptyQuestionTextIsRejected() {
        // Pin defensive nil-collapse — empty question text would
        // render an empty header band; surface it as a parse failure
        // so the view can fall through to its empty-state branch.
        XCTAssertNil(PermissionAskUserQuestionCardBody.Question(raw: ["question": ""]))
        XCTAssertNil(PermissionAskUserQuestionCardBody.Question(raw: [:]))
    }

    func testOptionsWithoutLabelAreSkipped() throws {
        let raw =
            [
                "question": "Pick one",
                "options": [
                    ["label": "A"],
                    ["description": "no label"],
                    ["label": ""],
                    ["label": "B"],
                ],
            ] as [String: Any]
        let q = try XCTUnwrap(PermissionAskUserQuestionCardBody.Question(raw: raw))
        XCTAssertEqual(q.options.map(\.label), ["A", "B"])
    }

    func testMissingOptionsArrayParsesAsEmpty() throws {
        let q = try XCTUnwrap(
            PermissionAskUserQuestionCardBody.Question(raw: ["question": "Free form?"]))
        XCTAssertTrue(q.options.isEmpty)
        // Even an empty-options question is parseable — the view will
        // surface only the Other input row in that branch.
    }
}
