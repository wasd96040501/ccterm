import AgentSDK
import Foundation

/// SwiftUI-free state machine for the AskUserQuestion wizard (migration plan
/// §4.5). Lifted **verbatim** out of the SwiftUI `PermissionAskUserQuestionCardBody`
/// (`PermissionAskUserQuestionCardBody.swift`) — the `Question`/`Option`
/// decoders, `composedAnswer`, `commitAnswer`, `goBack` rehydration,
/// `confirmEnabled`, `buildUpdatedInput`, plus the per-question selection state
/// — with the `@State`/`@FocusState` SwiftUI machinery replaced by plain stored
/// properties and explicit action entry points.
///
/// The model is **view-private interaction state** (single reader: the wizard
/// VC), so it is a plain `final class`, NOT `@Observable` (root `CLAUDE.md`
/// data-flow rule: "The only `@Observable` a view may construct are
/// view-private interaction state machines" — but those need observation; here
/// the VC drives `rebuildForCurrentQuestion()` imperatively after every
/// mutation, so no observation is needed). Every mutating action calls
/// `onChange` so the owning `AskUserQuestionCardViewController` rebuilds its
/// arranged subviews — the AppKit analogue of SwiftUI body re-eval.
///
/// `@FocusState otherFocused` is intentionally NOT a model field — AppKit
/// first-responder ownership lives on the VC (§4.5-3). The model exposes the
/// `otherEditing` flag (whether the Other row should render its text field) and
/// the VC translates that into `makeFirstResponder` calls synchronously.
///
/// The model owns NO timers / monitors / views, so it needs no teardown beyond
/// dropping the callbacks; the VC clears them in its own teardown.
@MainActor
final class AskUserQuestionModel {

    // MARK: - Decoded payload models (verbatim from PermissionAskUserQuestionCardBody)

    /// Decoded view of one entry in `rawInput["questions"]`.
    /// Verbatim from `PermissionAskUserQuestionCardBody.Question`
    /// (`PermissionAskUserQuestionCardBody.swift:497-511`).
    struct Question {
        let header: String?
        let question: String
        let multiSelect: Bool
        let options: [Option]

        init?(raw: [String: Any]) {
            guard let q = raw["question"] as? String, !q.isEmpty else { return nil }
            self.question = q
            self.header = raw["header"] as? String
            self.multiSelect = (raw["multiSelect"] as? Bool) ?? false
            let rawOptions = raw["options"] as? [[String: Any]] ?? []
            self.options = rawOptions.compactMap(Option.init(raw:))
        }
    }

    /// Verbatim from `PermissionAskUserQuestionCardBody.Option`
    /// (`PermissionAskUserQuestionCardBody.swift:513-522`).
    struct Option {
        let label: String
        let description: String?

        init?(raw: [String: Any]) {
            guard let l = raw["label"] as? String, !l.isEmpty else { return nil }
            self.label = l
            self.description = raw["description"] as? String
        }
    }

    // MARK: - Inputs

    let request: PermissionRequest
    private let onSubmit: ([String: Any]?) -> Void
    private let onCancel: () -> Void

    /// Fired after a STRUCTURAL state mutation (option pick, Other
    /// engage/collapse, question advance / back-nav) so the VC rebuilds its
    /// arranged subviews (the AppKit analogue of SwiftUI body re-eval). Set by
    /// the VC after construction so the initial decode doesn't fire a rebuild
    /// before the VC's views exist.
    var onChange: (() -> Void)?

    /// Fired on a PURE Other text change (`commitOtherText`). The VC reconciles
    /// the existing rows IN PLACE (Confirm-enable + the Other checkmark) WITHOUT
    /// tearing down the live editing field (parity blocker fix — the SwiftUI
    /// `TextField(text: $otherText)` stayed a stable identity across text
    /// changes, never rebuilt). A nil callback (or routing a text change through
    /// `onChange`) would recreate the focused `NSTextField` on every keystroke,
    /// clobbering the user's input and resigning the field editor mid-edit.
    var onOtherTextChanged: (() -> Void)?

    // MARK: - State (plain stored props — lifted from the SwiftUI @State block)

    /// `PermissionAskUserQuestionCardBody.swift:59`.
    private(set) var currentIndex: Int = 0
    /// Committed answers, keyed by the question text (CLI round-trip contract,
    /// `:60-63`).
    private(set) var answers: [String: String] = [:]
    /// Single-select pick for the in-flight question (`:64-66`).
    private(set) var singleSelectIndex: Int?
    /// Multi-select toggled indices for the in-flight question (`:67-68`).
    private(set) var multiSelectIndices: Set<Int> = []
    /// Free-form text typed into the "Other" row (`:69-70`).
    private(set) var otherText: String = ""
    /// Whether Other is part of the answer (`:71-73`).
    private(set) var otherActive: Bool = false
    /// `true` while the Other row renders its text field (`:74-76`). The VC
    /// reads this and drives `makeFirstResponder` synchronously — there is no
    /// `@FocusState` field here (§4.5-3).
    private(set) var otherEditing: Bool = false

    // MARK: - Init

    init(
        request: PermissionRequest,
        onSubmit: @escaping ([String: Any]?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    /// macOS 26 SDK workaround: an empty `nonisolated deinit`.
    nonisolated deinit {}

    // MARK: - Decoded payload (verbatim :81-90)

    /// Decoded questions list. Empty when the payload is missing / malformed —
    /// the VC renders its fallback in that case.
    private(set) lazy var questions: [Question] = {
        guard let raw = request.rawInput["questions"] as? [[String: Any]] else { return [] }
        return raw.compactMap(Question.init(raw:))
    }()

    /// The in-flight question, bounds-checked (`:86-90`).
    var current: Question? {
        let qs = questions
        guard currentIndex >= 0, currentIndex < qs.count else { return nil }
        return qs[currentIndex]
    }

    // MARK: - Derived (verbatim :302-304, :339-355)

    /// `:302-304`.
    var trimmedOther: String {
        otherText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `:339`.
    var isLastQuestion: Bool { currentIndex >= questions.count - 1 }

    /// `:341-346`.
    func isOptionSelected(index: Int) -> Bool {
        guard let q = current else { return false }
        if q.multiSelect {
            return multiSelectIndices.contains(index)
        }
        return singleSelectIndex == index
    }

    /// `:348-355`.
    var confirmEnabled: Bool {
        guard let q = current else { return false }
        if q.multiSelect {
            return !multiSelectIndices.isEmpty || (otherActive && !trimmedOther.isEmpty)
        }
        if singleSelectIndex != nil { return true }
        return otherActive && !trimmedOther.isEmpty
    }

    /// "Next question" when there's another question after this one, "Confirm"
    /// on the final question (`:333-335`).
    var confirmLabel: String {
        isLastQuestion ? String(localized: "Confirm") : String(localized: "Next question")
    }

    // MARK: - Public action entry points (drive the state machine)
    //
    // These are the seams the wizard VC's controls call AND the
    // `AskUserQuestionModelTests` drive directly. Each mutates state and fires
    // `onChange` so the view rebuilds.

    /// Tap an option row (`:357-373`). Multi-select toggles; single-select sets
    /// the pick and clears any Other state so the two answer slots stay mutually
    /// exclusive. The `@FocusState otherFocused = false` write in the SwiftUI
    /// source is replaced by the VC resigning the Other field (it observes the
    /// `otherEditing` flip in `rebuild`).
    func selectOption(_ index: Int) {
        guard let q = current else { return }
        if q.multiSelect {
            if multiSelectIndices.contains(index) {
                multiSelectIndices.remove(index)
            } else {
                multiSelectIndices.insert(index)
            }
            onChange?()
            return
        }
        // Single-select: pick the option and clear any Other state.
        singleSelectIndex = index
        otherActive = false
        otherEditing = false
        otherText = ""
        onChange?()
    }

    /// Alias for `selectOption` for the multi-select call site (the test API
    /// names it `toggleOption`); identical semantics (`handleOptionTap` is the
    /// single SwiftUI entry point for both).
    func toggleOption(_ index: Int) { selectOption(index) }

    /// Engage the Other row — reveal the text field (`:240-247`). The SwiftUI
    /// source set `otherEditing = true` then deferred `otherFocused = true` to
    /// the next runloop; here the VC makes the field first responder
    /// SYNCHRONOUSLY off the `otherEditing` flip (§4.5-3 forbids the async hop).
    /// Single-select: engaging Other clears the option pick.
    func engageOther() {
        guard let q = current else { return }
        otherEditing = true
        if !q.multiSelect { singleSelectIndex = nil }
        onChange?()
    }

    /// The Other text field's text changed (`:280-282`). Non-empty text marks
    /// Other active. Mirrors `.onChange(of: otherText)`. Fires `onOtherTextChanged`
    /// (a lightweight in-place reconcile), NOT `onChange` — a full rebuild here
    /// would destroy and recreate the live, focused `NSTextField` on every
    /// keystroke (parity blocker).
    func commitOtherText(_ text: String) {
        otherText = text
        if !text.isEmpty { otherActive = true }
        onOtherTextChanged?()
    }

    /// The Other field lost focus / editing ended (`:283-287`). Collapse back to
    /// the button form; if the trimmed text is empty, Other is no longer active.
    /// Mirrors the `.onChange(of: otherFocused)` blur branch.
    func endOtherEditing() {
        otherEditing = false
        if trimmedOther.isEmpty { otherActive = false }
        onChange?()
    }

    /// The single confirm() source of truth (`:375-380`). Composes the answer
    /// for the current question; no-op if empty; otherwise commits + advances /
    /// submits.
    func confirm() {
        guard let q = current else { return }
        let answer = composedAnswer(for: q)
        guard !answer.isEmpty else { return }
        commitAnswer(question: q, answer: answer)
    }

    /// Cancel the wizard (`onCancel` → deny / dismiss). Reached from
    /// `cancelOperation` and the Cancel button.
    func cancel() {
        onCancel()
    }

    /// Back-nav (`:412-438`). Re-hydrates the prior question's selection from
    /// `answers` by exact label match → comma-split → unmatched→Other.
    func goBack() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
        resetPerQuestionState()
        // Re-hydrate the previous question's answer into the picker.
        if let q = current, let prior = answers[q.question] {
            if let idx = q.options.firstIndex(where: { $0.label == prior }) {
                if q.multiSelect { multiSelectIndices = [idx] } else { singleSelectIndex = idx }
            } else if q.multiSelect {
                let parts = prior.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                multiSelectIndices = Set(
                    parts.compactMap { p in q.options.firstIndex(where: { $0.label == p }) })
                let extras = parts.filter { p in !q.options.contains(where: { $0.label == p }) }
                if !extras.isEmpty {
                    otherText = extras.joined(separator: ", ")
                    otherActive = true
                }
            } else {
                otherText = prior
                otherActive = true
            }
        }
        onChange?()
    }

    // MARK: - Answer composition / commit (verbatim :382-454)

    /// `:382-398`.
    func composedAnswer(for q: Question) -> String {
        if q.multiSelect {
            var parts = multiSelectIndices.sorted().compactMap { idx -> String? in
                guard idx < q.options.count else { return nil }
                return q.options[idx].label
            }
            if otherActive, !trimmedOther.isEmpty { parts.append(trimmedOther) }
            return parts.joined(separator: ", ")
        }
        if let idx = singleSelectIndex, idx < q.options.count {
            return q.options[idx].label
        }
        if otherActive, !trimmedOther.isEmpty {
            return trimmedOther
        }
        return ""
    }

    /// `:400-410`, minus the `withAnimation` wrapper (D5: instant / opacity-only
    /// transitions are owned by the VC, not the model).
    private func commitAnswer(question q: Question, answer: String) {
        answers[q.question] = answer
        if isLastQuestion {
            onSubmit(buildUpdatedInput())
            return
        }
        currentIndex += 1
        resetPerQuestionState()
        onChange?()
    }

    /// `:440-447`, minus `otherFocused` (the VC resigns the field off the
    /// `otherEditing = false` flip).
    private func resetPerQuestionState() {
        singleSelectIndex = nil
        multiSelectIndices = []
        otherText = ""
        otherActive = false
        otherEditing = false
    }

    /// `:449-454`. The CLI `AskUserQuestionTool` contract: `answers` keyed by
    /// the original question string + the original `questions` payload
    /// round-tripped.
    func buildUpdatedInput() -> [String: Any] {
        var payload: [String: Any] = [:]
        if let raw = request.rawInput["questions"] { payload["questions"] = raw }
        payload["answers"] = answers
        return payload
    }
}
