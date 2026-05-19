import AgentSDK
import SwiftUI

/// Interactive AskUserQuestion picker shown in the floating
/// permission card. Owns the full card chrome (header / question /
/// option vstack / cancel ✕ / submit) — `PermissionCardView` skips
/// its generic header + button row for this kind.
///
/// **Interaction model** (ported from ccmaster's `QuestionView`):
///
/// - Options stack vertically as full-width rounded "buttons". Hover
///   lightens the row, press darkens it; selected rows pick up the
///   accent fill + a ✓.
/// - An auto-injected "Other" row sits at the bottom of every
///   question. Clicking it focuses a free-form `TextField` rendered
///   at the same row geometry (corner radius + height + insets), so
///   the input visually reads as another option row that happens to
///   accept text.
/// - For single-select questions with no "Other" interest, clicking
///   an option commits immediately and advances; for single-select +
///   typed-Other, or any multi-select, a primary-filled "Submit" /
///   "Next" row collects the choices at the bottom.
/// - Multi-question lists step one-at-a-time. A left chevron in the
///   top row jumps back. The right ✕ (or Esc) cancels the whole
///   request via `pending.request.deny()`.
///
/// **Payload contract**: on the final question's commit, the body
/// invokes `onSubmit({ "questions": <original>, "answers": [Q: A] })`.
/// The host turns that into `request.allowOnce(updatedInput:)` so the
/// CLI's `AskUserQuestionTool` resolves with the answers map.
struct PermissionAskUserQuestionCardBody: View {

    // MARK: - Geometry

    static let rowHeight: CGFloat = 36
    static let rowCornerRadius: CGFloat = 8
    static let rowHPadding: CGFloat = 12
    static let rowSpacing: CGFloat = 6
    static let groupSpacing: CGFloat = 12

    // MARK: - Inputs

    let request: PermissionRequest
    let onSubmit: ([String: Any]?) -> Void
    let onCancel: () -> Void

    // MARK: - State

    @State private var currentIndex: Int = 0
    /// Committed answers, keyed by the question text (matches the
    /// CLI's expectation that the answers map round-trips through the
    /// original `question` string).
    @State private var answers: [String: String] = [:]
    /// Single-select picks for the in-flight question (built-in
    /// option index only — "Other" is tracked via `otherActive`).
    @State private var singleSelectIndex: Int? = nil
    /// Multi-select toggled indices for the in-flight question.
    @State private var multiSelectIndices: Set<Int> = []
    /// Free-form text typed into the "Other" row.
    @State private var otherText: String = ""
    /// Whether the user has engaged the Other row (focused it once or
    /// toggled it on in multi-select). Drives whether `otherText`
    /// contributes to the eventual answer.
    @State private var otherActive: Bool = false
    @FocusState private var otherFocused: Bool

    // MARK: - Decoded payload

    private var questions: [Question] {
        guard let raw = request.rawInput["questions"] as? [[String: Any]] else { return [] }
        return raw.compactMap(Question.init(raw:))
    }

    private var current: Question? {
        let qs = questions
        guard currentIndex >= 0, currentIndex < qs.count else { return nil }
        return qs[currentIndex]
    }

    // MARK: - Body

    var body: some View {
        if questions.isEmpty {
            fallback
        } else {
            VStack(alignment: .leading, spacing: Self.groupSpacing) {
                topRow
                if let q = current {
                    questionHeader(q)
                    optionsVStack(q)
                    if showsSubmitRow(for: q) {
                        submitRow(for: q)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(escapeKeyCapture)
        }
    }

    // MARK: - Top row (progress + back + cancel)

    @ViewBuilder
    private var topRow: some View {
        HStack(alignment: .center, spacing: 8) {
            if currentIndex > 0 {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Previous question"))
            }
            if questions.count > 1 {
                Text("\(currentIndex + 1) / \(questions.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    }
            }
            Spacer(minLength: 0)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(String(localized: "Cancel question"))
        }
    }

    // MARK: - Question header

    @ViewBuilder
    private func questionHeader(_ q: Question) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header = q.header, !header.isEmpty {
                Text(header)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                    }
            }
            Text(q.question)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Options vstack

    @ViewBuilder
    private func optionsVStack(_ q: Question) -> some View {
        VStack(spacing: Self.rowSpacing) {
            ForEach(Array(q.options.enumerated()), id: \.offset) { idx, opt in
                optionRow(question: q, index: idx, option: opt)
            }
            otherRow(question: q)
        }
    }

    @ViewBuilder
    private func optionRow(question q: Question, index: Int, option: Option) -> some View {
        let selected = isOptionSelected(question: q, index: index)
        Button {
            handleOptionTap(question: q, index: index, option: option)
        } label: {
            optionRowLabel(option: option, showsCheck: selected)
        }
        .buttonStyle(AskOptionRowStyle(selected: selected))
    }

    @ViewBuilder
    private func optionRowLabel(option: Option, showsCheck: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(option.label)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                if let desc = option.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if showsCheck {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
            }
        }
    }

    // MARK: - "Other" input row

    @ViewBuilder
    private func otherRow(question q: Question) -> some View {
        let isSelected = otherActive
        HStack(alignment: .center, spacing: 8) {
            TextField(
                String(localized: "Other (type your own answer…)"),
                text: $otherText
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .focused($otherFocused)
            .onSubmit { commitOtherIfPossible(question: q) }
            .onChange(of: otherText) { _, newValue in
                // The first keystroke promotes Other to "active"
                // — visually it picks up the selected fill so
                // the user can see it counts as their choice.
                if !newValue.isEmpty { otherActive = true }
            }
            if otherFocused && !trimmedOther.isEmpty {
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    }
            }
        }
        .padding(.horizontal, Self.rowHPadding)
        // Fixed height — input rows always carry a single line, so
        // sharing the option-row 36pt floor keeps them in the same
        // visual rhythm. minHeight would otherwise let the parent
        // VStack stretch the row to absorb leftover vertical space.
        .frame(height: Self.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: Self.rowCornerRadius, style: .continuous)
                .fill(otherBackground(focused: otherFocused, selected: isSelected))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.rowCornerRadius, style: .continuous)
                .strokeBorder(
                    otherStroke(focused: otherFocused, selected: isSelected),
                    lineWidth: otherFocused || isSelected ? 1 : 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            otherFocused = true
            otherActive = true
        }
    }

    private var trimmedOther: String {
        otherText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func otherBackground(focused: Bool, selected: Bool) -> Color {
        if selected || focused {
            return Color.accentColor.opacity(0.12)
        }
        return Color.primary.opacity(0.04)
    }

    private func otherStroke(focused: Bool, selected: Bool) -> Color {
        if focused || selected {
            return Color.accentColor.opacity(0.55)
        }
        return Color(nsColor: .separatorColor)
    }

    // MARK: - Submit row

    private func showsSubmitRow(for q: Question) -> Bool {
        // A submit row is needed any time a single click can't carry
        // the answer: multi-select, or single-select with the user
        // engaged in the Other input.
        q.multiSelect || otherActive
    }

    @ViewBuilder
    private func submitRow(for q: Question) -> some View {
        let label = isLastQuestion ? String(localized: "Submit") : String(localized: "Next")
        let enabled = submitEnabled(for: q)
        Button {
            handleSubmitTap(question: q)
        } label: {
            HStack {
                Spacer(minLength: 0)
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.7))
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(AskSubmitRowStyle(enabled: enabled))
        .disabled(!enabled)
        .keyboardShortcut(.defaultAction)
    }

    // MARK: - Logic

    private var isLastQuestion: Bool { currentIndex >= questions.count - 1 }

    private func isOptionSelected(question q: Question, index: Int) -> Bool {
        if q.multiSelect {
            return multiSelectIndices.contains(index)
        }
        return singleSelectIndex == index
    }

    private func submitEnabled(for q: Question) -> Bool {
        if q.multiSelect {
            return !multiSelectIndices.isEmpty || !trimmedOther.isEmpty
        }
        // Single-select branch is only reached with submit row when
        // the user is composing Other. Require non-empty text.
        return !trimmedOther.isEmpty
    }

    private func handleOptionTap(question q: Question, index: Int, option: Option) {
        if q.multiSelect {
            if multiSelectIndices.contains(index) {
                multiSelectIndices.remove(index)
            } else {
                multiSelectIndices.insert(index)
            }
            return
        }
        // Single-select: commit immediately.
        singleSelectIndex = index
        otherActive = false  // user picked a real option, drop Other engagement
        otherText = ""
        commitAnswer(question: q, answer: option.label)
    }

    private func handleSubmitTap(question q: Question) {
        let pieces: [String]
        if q.multiSelect {
            var parts = multiSelectIndices.sorted().compactMap { idx -> String? in
                guard idx < q.options.count else { return nil }
                return q.options[idx].label
            }
            if !trimmedOther.isEmpty { parts.append(trimmedOther) }
            pieces = parts
        } else {
            pieces = [trimmedOther]
        }
        let joined = pieces.joined(separator: ", ")
        commitAnswer(question: q, answer: joined)
    }

    private func commitOtherIfPossible(question q: Question) {
        guard !trimmedOther.isEmpty else { return }
        if q.multiSelect {
            // Don't auto-submit on Enter in multi-select; the user may
            // still want to tick more boxes. Treat Enter as "I'm done
            // with this field, but Submit is still the explicit
            // commit." Move focus off so the field commits its edit.
            otherActive = true
            otherFocused = false
            return
        }
        // Single-select + typed Other → Enter commits.
        commitAnswer(question: q, answer: trimmedOther)
    }

    private func commitAnswer(question q: Question, answer: String) {
        answers[q.question] = answer
        if isLastQuestion {
            onSubmit(buildUpdatedInput())
            return
        }
        currentIndex += 1
        resetPerQuestionState()
    }

    private func goBack() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
        resetPerQuestionState()
        // Restore the previous answer into the picker so the user can
        // see what they had picked. Single-select: try to match an
        // option; otherwise treat as Other text.
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
    }

    private func resetPerQuestionState() {
        singleSelectIndex = nil
        multiSelectIndices = []
        otherText = ""
        otherActive = false
        otherFocused = false
    }

    private func buildUpdatedInput() -> [String: Any] {
        var payload: [String: Any] = [:]
        if let raw = request.rawInput["questions"] { payload["questions"] = raw }
        payload["answers"] = answers
        return payload
    }

    // MARK: - Esc shortcut

    /// Hidden zero-size button so `.keyboardShortcut(.cancelAction)`
    /// reaches `onCancel` even when no focusable view is active.
    @ViewBuilder
    private var escapeKeyCapture: some View {
        Button(action: onCancel) { EmptyView() }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }

    // MARK: - Fallback for malformed payload

    @ViewBuilder
    private var fallback: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Claude wants to ask you a question"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(localized: "No questions were provided. Cancel to dismiss."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer(minLength: 0)
                Button(String(localized: "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: - Models

    /// Decoded view of one entry in `rawInput["questions"]`.
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

    struct Option {
        let label: String
        let description: String?

        init?(raw: [String: Any]) {
            guard let l = raw["label"] as? String, !l.isEmpty else { return nil }
            self.label = l
            self.description = raw["description"] as? String
        }
    }
}

// MARK: - Option row button style

/// Full-width row look shared by all option rows. Idle / hover /
/// pressed / selected states are folded into the fill + stroke so the
/// row reads as a native button (press deflation, hover brightening).
private struct AskOptionRowStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        RowSurface(configuration: configuration, selected: selected)
    }

    private struct RowSurface: View {
        let configuration: Configuration
        let selected: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, PermissionAskUserQuestionCardBody.rowHPadding)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: PermissionAskUserQuestionCardBody.rowHeight)
                .background {
                    RoundedRectangle(
                        cornerRadius: PermissionAskUserQuestionCardBody.rowCornerRadius,
                        style: .continuous
                    )
                    .fill(fill(pressed: configuration.isPressed))
                }
                .overlay {
                    RoundedRectangle(
                        cornerRadius: PermissionAskUserQuestionCardBody.rowCornerRadius,
                        style: .continuous
                    )
                    .strokeBorder(stroke, lineWidth: selected ? 1 : 0.5)
                }
                .contentShape(Rectangle())
                .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
                .onHover { hovering = $0 }
                .animation(.linear(duration: 0.08), value: hovering)
                .animation(.linear(duration: 0.06), value: configuration.isPressed)
        }

        private func fill(pressed: Bool) -> Color {
            if selected {
                return pressed
                    ? Color.accentColor.opacity(0.22)
                    : Color.accentColor.opacity(0.12)
            }
            if pressed { return Color.primary.opacity(0.14) }
            if hovering { return Color.primary.opacity(0.08) }
            return Color.primary.opacity(0.04)
        }

        private var stroke: Color {
            selected ? Color.accentColor.opacity(0.55) : Color(nsColor: .separatorColor)
        }
    }
}

// MARK: - Submit row style

/// Primary accent-filled row sharing the option-row geometry. Used by
/// the bottom Submit/Next row so the "confirm" button visually
/// belongs to the same row family as the option choices.
private struct AskSubmitRowStyle: ButtonStyle {
    let enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        RowSurface(configuration: configuration, enabled: enabled)
    }

    private struct RowSurface: View {
        let configuration: Configuration
        let enabled: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, PermissionAskUserQuestionCardBody.rowHPadding)
                .frame(maxWidth: .infinity)
                .frame(minHeight: PermissionAskUserQuestionCardBody.rowHeight)
                .background {
                    RoundedRectangle(
                        cornerRadius: PermissionAskUserQuestionCardBody.rowCornerRadius,
                        style: .continuous
                    )
                    .fill(fill(pressed: configuration.isPressed))
                }
                .contentShape(Rectangle())
                .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
                .onHover { hovering = enabled && $0 }
                .animation(.linear(duration: 0.08), value: hovering)
                .animation(.linear(duration: 0.06), value: configuration.isPressed)
        }

        private func fill(pressed: Bool) -> Color {
            if !enabled { return Color.accentColor.opacity(0.35) }
            if pressed { return Color.accentColor.opacity(0.85) }
            if hovering { return Color.accentColor.opacity(0.92) }
            return Color.accentColor
        }
    }
}

// MARK: - Previews

#Preview("Single-select with Other") {
    PermissionAskUserQuestionCardBody(
        request: PermissionRequest.makePreview(
            requestId: "preview-single",
            toolName: "AskUserQuestion",
            input: [
                "questions": [
                    [
                        "question":
                            "Should we keep backwards-compatibility shims for the old API?",
                        "header": "Compat",
                        "multiSelect": false,
                        "options": [
                            [
                                "label": "Yes, keep them",
                                "description": "Existing clients still need them",
                            ],
                            [
                                "label": "No, remove them",
                                "description": "Cleaner break, faster releases",
                            ],
                        ],
                    ]
                ]
            ]),
        onSubmit: { _ in },
        onCancel: {}
    )
    .padding(14)
    .frame(width: 520)
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Multi-select 2 of 3") {
    PermissionAskUserQuestionCardBody(
        request: PermissionRequest.makePreview(
            requestId: "preview-multi",
            toolName: "AskUserQuestion",
            input: [
                "questions": [
                    [
                        "question": "Which features should we enable in v1?",
                        "header": "Features",
                        "multiSelect": true,
                        "options": [
                            ["label": "Diff view", "description": "Side-by-side patches"],
                            ["label": "Inline syntax highlight"],
                            ["label": "Code folding"],
                        ],
                    ],
                    [
                        "question": "Pick the default theme.",
                        "header": "Theme",
                        "multiSelect": false,
                        "options": [
                            ["label": "Auto"],
                            ["label": "Light"],
                            ["label": "Dark"],
                        ],
                    ],
                ]
            ]),
        onSubmit: { _ in },
        onCancel: {}
    )
    .padding(14)
    .frame(width: 520)
    .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Empty fallback") {
    PermissionAskUserQuestionCardBody(
        request: PermissionRequest.makePreview(
            requestId: "preview-empty",
            toolName: "AskUserQuestion",
            input: [:]),
        onSubmit: { _ in },
        onCancel: {}
    )
    .padding(14)
    .frame(width: 520)
    .background(Color(nsColor: .windowBackgroundColor))
}
