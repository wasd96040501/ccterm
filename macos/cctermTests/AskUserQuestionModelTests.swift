import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// CI-gate logic tests for the AskUserQuestion wizard (migration plan §4.5).
///
/// Two layers, both driving the REAL production surface:
///
/// 1. **Decoder migration** — the 5 `Question`/`Option` decoder tests that used
///    to live in `PermissionAskUserQuestionCardBodyTests`, retargeted to
///    `AskUserQuestionModel.Question`/`.Option` (the SwiftUI body was deleted in
///    the same change).
///
/// 2. **State-machine** — drive the production
///    `AskUserQuestionCardViewController.init(request:onSubmit:onCancel:)` and
///    its model's PUBLIC action entry points (`selectOption` / `toggleOption` /
///    `engageOther` / `commitOtherText` / `goBack` / `confirm` / `cancel`),
///    asserting on the production model's observable state (`currentIndex`,
///    `answers`, `composedAnswer`, `confirmEnabled`) and the `onSubmit` /
///    `onCancel` callbacks firing. No test-only seam — the ONLY init is the
///    production one.
///
/// Parallel-safe: no `.shared`, no `UserDefaults.standard`, no
/// `NotificationCenter.default`, no `sleep`. Pure synchronous model drives.
@MainActor
final class AskUserQuestionModelTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Builders (real production VC + model)

    /// Build the production wizard VC for `input` and return its model + the
    /// recorded callbacks. Force `loadView` so `rebuildForCurrentQuestion` runs
    /// (mirrors the production mount).
    private func makeWizard(
        _ input: [String: Any]
    ) -> (
        vc: AskUserQuestionCardViewController, model: AskUserQuestionModel,
        submitted: () -> [String: Any]?, cancelCount: () -> Int
    ) {
        let request = PermissionRequest.makePreview(
            requestId: "req-ask", toolName: "AskUserQuestion", input: input)
        var lastSubmit: [String: Any]??
        var cancels = 0
        let vc = AskUserQuestionCardViewController(
            request: request,
            onSubmit: { lastSubmit = $0 },
            onCancel: { cancels += 1 })
        _ = vc.view  // force loadView → initial rebuild
        return (vc, vc.model, { lastSubmit ?? nil }, { cancels })
    }

    private func singleSelectInput() -> [String: Any] {
        [
            "questions": [
                [
                    "question": "Pick one",
                    "options": [
                        ["label": "opt0"],
                        ["label": "opt1"],
                        ["label": "opt2"],
                    ],
                ]
            ]
        ]
    }

    private func multiSelectInput() -> [String: Any] {
        [
            "questions": [
                [
                    "question": "Pick many",
                    "multiSelect": true,
                    "options": [
                        ["label": "opt0"],
                        ["label": "opt1"],
                        ["label": "opt2"],
                    ],
                ]
            ]
        ]
    }

    // MARK: - Migrated decoder tests (from PermissionAskUserQuestionCardBodyTests)

    func testParsesSingleQuestionWithOptions() throws {
        let raw =
            [
                "question": "Which auth method should we use?",
                "options": [["label": "OIDC"], ["label": "SAML"]],
            ] as [String: Any]
        let q = try XCTUnwrap(AskUserQuestionModel.Question(raw: raw))
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
        let q = try XCTUnwrap(AskUserQuestionModel.Question(raw: raw))
        XCTAssertEqual(q.header, "Features")
        XCTAssertTrue(q.multiSelect)
        XCTAssertEqual(q.options.count, 2)
        XCTAssertEqual(q.options[0].description, "Side-by-side patches")
        XCTAssertNil(q.options[1].description)
    }

    func testEmptyQuestionTextIsRejected() {
        XCTAssertNil(AskUserQuestionModel.Question(raw: ["question": ""]))
        XCTAssertNil(AskUserQuestionModel.Question(raw: [:]))
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
        let q = try XCTUnwrap(AskUserQuestionModel.Question(raw: raw))
        XCTAssertEqual(q.options.map(\.label), ["A", "B"])
    }

    func testMissingOptionsArrayParsesAsEmpty() throws {
        let q = try XCTUnwrap(
            AskUserQuestionModel.Question(raw: ["question": "Free form?"]))
        XCTAssertTrue(q.options.isEmpty)
    }

    // MARK: - Confirm-enable

    func testConfirmDisabledUntilSelection() {
        let (_, model, _, _) = makeWizard(singleSelectInput())
        XCTAssertFalse(model.confirmEnabled, "single-select: no pick → disabled")
        model.selectOption(0)
        XCTAssertTrue(model.confirmEnabled, "single-select: a pick → enabled")
    }

    func testMultiSelectConfirmRequiresAtLeastOne() {
        let (_, model, _, _) = makeWizard(multiSelectInput())
        XCTAssertFalse(model.confirmEnabled)
        model.toggleOption(0)
        XCTAssertTrue(model.confirmEnabled)
        // Toggling the same index off → back to empty → disabled.
        model.toggleOption(0)
        XCTAssertFalse(model.confirmEnabled, "multi-select: last index removed → disabled")
        model.toggleOption(1)
        XCTAssertTrue(model.confirmEnabled)
    }

    func testOtherEnablesConfirmWhenNonEmpty() {
        let (_, model, _, _) = makeWizard(singleSelectInput())
        model.engageOther()
        model.commitOtherText("   ")
        XCTAssertFalse(model.confirmEnabled, "whitespace-only Other trims empty → disabled")
        model.commitOtherText("hi")
        XCTAssertTrue(model.confirmEnabled)
    }

    // MARK: - Composed answer

    func testComposedAnswerSingle() throws {
        let (_, model, _, _) = makeWizard(singleSelectInput())
        model.selectOption(1)
        let q = try XCTUnwrap(model.current)
        XCTAssertEqual(model.composedAnswer(for: q), q.options[1].label)
    }

    func testComposedAnswerMultiJoinsSorted() throws {
        let (_, model, _, _) = makeWizard(multiSelectInput())
        // Toggle out of order — composed answer must sort by index.
        model.toggleOption(2)
        model.toggleOption(0)
        let q = try XCTUnwrap(model.current)
        XCTAssertEqual(model.composedAnswer(for: q), "opt0, opt2")
        // Add a non-empty Other → appended last.
        model.engageOther()
        model.commitOtherText("x")
        XCTAssertEqual(model.composedAnswer(for: q), "opt0, opt2, x")
    }

    func testSingleSelectAndOtherMutuallyExclusive() {
        let (_, model, _, _) = makeWizard(singleSelectInput())
        model.selectOption(0)
        XCTAssertEqual(model.singleSelectIndex, 0)
        // Engaging Other + typing clears the single-select pick.
        model.engageOther()
        model.commitOtherText("x")
        XCTAssertNil(model.singleSelectIndex, "engaging Other clears the single pick")
        XCTAssertTrue(model.otherActive)
        // Re-selecting an option clears Other.
        model.selectOption(1)
        XCTAssertFalse(model.otherActive, "re-selecting an option clears Other active")
        XCTAssertTrue(model.otherText.isEmpty, "re-selecting an option clears Other text")
        XCTAssertEqual(model.singleSelectIndex, 1)
    }

    // MARK: - Advance / final submit

    func testConfirmAdvancesThenFinalSubmits() throws {
        let input: [String: Any] = [
            "questions": [
                [
                    "question": "Q1",
                    "options": [["label": "a1"], ["label": "b1"]],
                ],
                [
                    "question": "Q2",
                    "options": [["label": "a2"], ["label": "b2"]],
                ],
            ]
        ]
        let (_, model, submitted, _) = makeWizard(input)

        // Answer Q1 → advance, no submit yet.
        model.selectOption(0)
        model.confirm()
        XCTAssertEqual(model.currentIndex, 1, "confirm on a non-final question advances")
        XCTAssertNil(submitted(), "onSubmit must NOT fire until the final question")
        XCTAssertEqual(model.answers["Q1"], "a1")

        // Answer Q2 → final submit fires exactly once.
        model.selectOption(1)
        model.confirm()
        let payload = try XCTUnwrap(submitted(), "final confirm fires onSubmit once")
        let answers = try XCTUnwrap(payload["answers"] as? [String: String])
        XCTAssertEqual(answers["Q1"], "a1")
        XCTAssertEqual(answers["Q2"], "b2")
        // The original questions payload round-trips.
        XCTAssertNotNil(payload["questions"], "the original questions payload round-trips")
    }

    // MARK: - Back-nav rehydration

    func testGoBackRehydratesSingle() throws {
        let input: [String: Any] = [
            "questions": [
                [
                    "question": "Q1",
                    "options": [["label": "a1"], ["label": "b1"]],
                ],
                [
                    "question": "Q2",
                    "options": [["label": "a2"], ["label": "b2"]],
                ],
            ]
        ]
        let (_, model, _, _) = makeWizard(input)
        model.selectOption(1)  // pick "b1"
        model.confirm()  // advance to Q2
        XCTAssertEqual(model.currentIndex, 1)
        model.goBack()
        XCTAssertEqual(model.currentIndex, 0)
        XCTAssertEqual(
            model.singleSelectIndex, 1,
            "goBack rehydrates the prior single pick by label match")
    }

    func testGoBackRehydratesMultiWithExtras() throws {
        let input: [String: Any] = [
            "questions": [
                [
                    "question": "Q1",
                    "multiSelect": true,
                    "options": [["label": "A"], ["label": "B"]],
                ],
                [
                    "question": "Q2",
                    "options": [["label": "a2"], ["label": "b2"]],
                ],
            ]
        ]
        let (_, model, _, _) = makeWizard(input)
        // Build a prior multi answer "A, custom" — A is an option, custom is not.
        model.toggleOption(0)  // A
        model.engageOther()
        model.commitOtherText("custom")
        model.confirm()  // advances; answers["Q1"] == "A, custom"
        XCTAssertEqual(model.answers["Q1"], "A, custom")
        XCTAssertEqual(model.currentIndex, 1)

        model.goBack()
        XCTAssertEqual(model.currentIndex, 0)
        XCTAssertEqual(
            model.multiSelectIndices, [0],
            "matched option label rehydrates the toggle")
        XCTAssertTrue(model.otherActive, "unmatched extra rehydrates Other active")
        XCTAssertEqual(model.otherText, "custom", "unmatched extra rehydrates Other text")
    }

    // MARK: - Cancel

    func testCancelFiresOnCancel() {
        let (_, model, _, cancelCount) = makeWizard(singleSelectInput())
        model.cancel()
        XCTAssertEqual(cancelCount(), 1, "cancel() fires onCancel exactly once")
    }

    // MARK: - Empty fallback

    func testEmptyPayloadRendersFallback() {
        let (vc, model, _, cancelCount) = makeWizard([:])
        XCTAssertTrue(model.questions.isEmpty, "[:] → no questions")
        XCTAssertNil(model.current, "no current question in the fallback branch")
        // The fallback still wires cancel.
        XCTAssertNotNil(
            vc.cancelButtonForTesting, "the fallback renders a lone Cancel button")
        model.cancel()
        XCTAssertEqual(cancelCount(), 1, "cancel() fires onCancel in the fallback branch too")
    }

    // MARK: - View-observation getters track production state (§ test-realness #2)

    /// The header / option-row / confirm-button getters reflect the real
    /// production view tree: progress chip text, option-row count, and the
    /// Confirm button's `isEnabled` tracking `model.confirmEnabled`.
    func testViewGettersTrackModelState() throws {
        let input: [String: Any] = [
            "questions": [
                [
                    "question": "Q1",
                    "options": [["label": "a1"], ["label": "b1"]],
                ],
                [
                    "question": "Q2",
                    "options": [["label": "a2"], ["label": "b2"], ["label": "c2"]],
                ],
            ]
        ]
        let (vc, model, _, _) = makeWizard(input)

        // Q1 (index 0 of 2).
        XCTAssertEqual(try XCTUnwrap(vc.headerForTesting).progressText, "1 / 2")
        XCTAssertEqual(vc.optionRowsForTesting.count, 2, "Q1 has 2 options")
        let confirm0 = try XCTUnwrap(vc.confirmButtonForTesting)
        XCTAssertFalse(model.confirmEnabled, "no pick yet")
        XCTAssertFalse(confirm0.isEnabled, "Confirm disabled tracks model.confirmEnabled")

        model.selectOption(0)
        let confirm1 = try XCTUnwrap(vc.confirmButtonForTesting)
        XCTAssertTrue(model.confirmEnabled)
        XCTAssertTrue(confirm1.isEnabled, "Confirm enabled tracks model.confirmEnabled after a pick")

        // Advance → Q2 (index 1 of 2), 3 options.
        model.confirm()
        XCTAssertEqual(try XCTUnwrap(vc.headerForTesting).progressText, "2 / 2")
        XCTAssertEqual(vc.optionRowsForTesting.count, 3, "Q2 has 3 options")
        XCTAssertEqual(
            try XCTUnwrap(vc.headerForTesting).questionText, "Q2",
            "the header shows the in-flight question")
    }

    // MARK: - Confirm keyboard seam (§4.5-2 — root-Return disabled-guard)

    /// Drive confirm via the PRODUCTION keyboard path (the wizard root's
    /// `keyDown` Return → `onReturn` → the VC's `confirm()` disabled-guard),
    /// NOT `model.confirm()` directly. With no selection the guard holds (no
    /// advance / submit); after a pick the same key advances. This covers the
    /// VC-level `guard model.confirmEnabled` that the button + both keyboard
    /// paths rely on (the model's own `confirm()` only checks composedAnswer).
    func testRootReturnHonorsConfirmDisabledGuard() throws {
        let input: [String: Any] = [
            "questions": [
                ["question": "Q1", "options": [["label": "a1"], ["label": "b1"]]],
                ["question": "Q2", "options": [["label": "a2"], ["label": "b2"]]],
            ]
        ]
        let (vc, model, submitted, _) = makeWizard(input)

        // Return with NO selection → the VC's disabled-guard holds: no advance.
        vc.view.keyDown(with: Self.returnKeyEvent())
        XCTAssertEqual(model.currentIndex, 0, "root-Return with no pick must NOT advance")
        XCTAssertNil(submitted())

        // Pick an option → Return advances through the same keyboard seam.
        model.selectOption(0)
        vc.view.keyDown(with: Self.returnKeyEvent())
        XCTAssertEqual(model.currentIndex, 1, "root-Return after a pick advances")
        XCTAssertEqual(model.answers["Q1"], "a1")
    }

    // MARK: - Other-field IME guard (§4.5-2 — Return during composition)

    /// Drive `AskOtherRowView.control(_:textView:doCommandBy:)` with a text view
    /// reporting `hasMarkedText() == true` (an active IME composition). The
    /// `insertNewline:` command must be left UNHANDLED (returns false → the
    /// field commits the composition) and `onSubmit` must NOT fire — so Return
    /// mid-IME never advances the wizard. The non-composing case returns true
    /// and fires `onSubmit`.
    func testOtherFieldReturnDuringIMECompositionDoesNotSubmit() {
        let row = AskOtherRowView(typedText: "", active: false, editing: true)
        var submits = 0
        row.onSubmit = { submits += 1 }

        // A real NSTextView with an ACTIVE marked-text composition (set via the
        // standard `setMarkedText` input path) — `hasMarkedText()` is then true
        // exactly as the field editor reports mid-IME.
        let composing = NSTextView(frame: .zero)
        composing.setMarkedText(
            " n", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(composing.hasMarkedText(), "the text view is mid-composition")
        let handledWhileComposing = row.control(
            row.editingField, textView: composing,
            doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertFalse(
            handledWhileComposing,
            "Return during IME composition is left unhandled (commits the composition)")
        XCTAssertEqual(submits, 0, "Return mid-IME must NOT submit / advance")

        // A text view with NO composition → Return is handled + submits once.
        let idle = NSTextView(frame: .zero)
        XCTAssertFalse(idle.hasMarkedText())
        let handledIdle = row.control(
            row.editingField, textView: idle,
            doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(handledIdle, "Return with no composition is handled by the row")
        XCTAssertEqual(submits, 1, "Return with no composition submits exactly once")
    }

    /// A synthetic Return key-down event (keyCode 36) for driving the wizard
    /// root's production `keyDown` path.
    private static func returnKeyEvent() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    }
}
