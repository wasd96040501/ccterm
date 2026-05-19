import AgentSDK
import SwiftUI

/// Interactive AskUserQuestion picker shown in the floating permission
/// card. Owns the full card chrome (question header + ✕, option vstack,
/// Deny / Confirm row) — `PermissionCardView` skips its generic header /
/// reason / button row for this kind.
///
/// **Interaction model**:
///
/// - The first row of the card is a single `HStack`: optional back
///   arrow, optional progress chip ("1/3"), optional header chip
///   ("Compat"), the question text (multi-line allowed), and the close
///   ✕ pinned to the trailing edge. There is no separate "top bar"
///   above the question.
/// - Options stack vertically as full-width rounded buttons. Hover
///   lightens the row; selected rows pick up an accent fill + ✓.
/// - An auto-injected "Other" row sits at the bottom of every
///   question. Click it to reveal an inline `TextField` (same row
///   geometry — 36pt tall, identical corner radius); type then move
///   focus elsewhere to collapse it back to a labelled button that
///   still shows the typed text + ✓.
/// - Single-select and Other are mutually exclusive — picking an
///   option clears any typed Other text; engaging Other clears the
///   single selection. Multi-select lets Other coexist with the
///   option toggles.
/// - The bottom row carries two buttons reused from
///   `PermissionDecisionButton`: **Deny** on the left (destructive),
///   **Confirm** on the right (primary). The top-right ✕ is a second
///   cancel affordance (Esc also fires it).
///
/// **Payload contract**: on the final question's Confirm the body
/// invokes `onSubmit({ "questions": <original>, "answers": [Q: A] })`.
/// The host turns that into `request.allowOnce(updatedInput:)` so the
/// CLI's `AskUserQuestionTool` resolves with the answers map.
struct PermissionAskUserQuestionCardBody: View {

    // MARK: - Geometry

    /// Single row height shared by every option row and the Other
    /// row. Kept fixed (not `minHeight`) for the Other row so its
    /// button-state and editing-state both render at exactly this
    /// height — eliminating the layout jump when Other transitions
    /// between collapsed and expanded forms.
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
    /// Single-select pick for the in-flight question (built-in option
    /// index only — "Other" is tracked via `otherActive`).
    @State private var singleSelectIndex: Int? = nil
    /// Multi-select toggled indices for the in-flight question.
    @State private var multiSelectIndices: Set<Int> = []
    /// Free-form text typed into the "Other" row.
    @State private var otherText: String = ""
    /// Whether Other should be treated as part of the answer (the user
    /// has focused it or typed into it at least once).
    @State private var otherActive: Bool = false
    /// `true` while the Other row renders its TextField; `false` while
    /// it renders as a plain option button.
    @State private var otherEditing: Bool = false
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
                if let q = current {
                    questionHeader(q)
                    optionsVStack(q)
                }
                decisionButtons
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(escapeKeyCapture)
        }
    }

    // MARK: - Question header (first row)

    /// Two-row header: the chip row (back arrow + progress + header
    /// chip) on top, then the question text on its own line below.
    /// The chip row is omitted entirely when none of the three chips
    /// are present (single question with no header chip), so a card
    /// with the bare minimum payload doesn't leave a blank band.
    /// The close ✕ has been retired — the bottom Cancel button is
    /// the single cancel affordance, mirroring the other kinds.
    ///
    /// Animation: the back chevron is wrapped in a real `if` so
    /// SwiftUI inserts / removes the view; `.transition(...)` on the
    /// Button plus `withAnimation { … }` in `goBack` / `commitAnswer`
    /// drive both the chevron's fade-in and the sibling progress
    /// chip's layout shift. Since Xcode 11.2, `.animation(value:)`
    /// does **not** trigger `.transition`, so an explicit
    /// `withAnimation` block is required for the chevron to fade
    /// rather than pop.
    @ViewBuilder
    private func questionHeader(_ q: Question) -> some View {
        let hasChipRow =
            currentIndex > 0 || questions.count > 1 || (q.header?.isEmpty == false)
        VStack(alignment: .leading, spacing: 6) {
            if hasChipRow {
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
                        .transition(
                            .opacity.combined(with: .move(edge: .leading)))
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
                    Spacer(minLength: 0)
                }
            }
            Text(q.question)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
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
            handleOptionTap(question: q, index: index)
        } label: {
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
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(AskOptionRowStyle(selected: selected))
    }

    // MARK: - Other row

    /// Two visual shapes that always render at `rowHeight` — no
    /// height jump on focus/blur. Button shape (default) reads as one
    /// more option row; editing shape exposes a `TextField`.
    @ViewBuilder
    private func otherRow(question q: Question) -> some View {
        if otherEditing {
            otherEditingRow(question: q)
        } else {
            otherButtonRow(question: q)
        }
    }

    @ViewBuilder
    private func otherButtonRow(question q: Question) -> some View {
        let showsTyped = !trimmedOther.isEmpty
        Button {
            otherEditing = true
            // FocusState lands on the next runloop once the TextField
            // is in the hierarchy.
            DispatchQueue.main.async { otherFocused = true }
            // Single-select: engaging Other clears the option pick so
            // the two answer slots are mutually exclusive.
            if !q.multiSelect { singleSelectIndex = nil }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Text(
                    showsTyped
                        ? otherText
                        : String(localized: "Other")
                )
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
                Spacer(minLength: 0)
                if otherActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(AskOptionRowStyle(selected: otherActive))
    }

    @ViewBuilder
    private func otherEditingRow(question q: Question) -> some View {
        HStack(alignment: .center, spacing: 8) {
            TextField(
                String(localized: "Type your own answer…"),
                text: $otherText
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .focused($otherFocused)
            .onChange(of: otherText) { _, newValue in
                if !newValue.isEmpty { otherActive = true }
            }
            .onChange(of: otherFocused) { _, focused in
                guard !focused else { return }
                otherEditing = false
                if trimmedOther.isEmpty { otherActive = false }
            }
        }
        .padding(.horizontal, Self.rowHPadding)
        .frame(height: Self.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: Self.rowCornerRadius, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.rowCornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
        }
        .contentShape(Rectangle())
    }

    private var trimmedOther: String {
        otherText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Decision buttons (bottom row)

    /// Two buttons that mirror the chrome shared by every other
    /// permission card kind: destructive Cancel on the left, primary
    /// Confirm / Next-question on the right. Confirm is disabled until
    /// an answer is collectable.
    @ViewBuilder
    private var decisionButtons: some View {
        HStack(spacing: 8) {
            PermissionDecisionButton(
                title: String(localized: "Cancel"),
                role: .destructive,
                action: onCancel)
            Spacer(minLength: 0)
            PermissionDecisionButton(
                title: confirmLabel,
                role: .primary,
                action: handleConfirm
            )
            .disabled(!confirmEnabled)
            .opacity(confirmEnabled ? 1 : 0.5)
            .keyboardShortcut(.defaultAction)
        }
    }

    /// "Next question" when there's another question after this one,
    /// "Confirm" on the final question.
    private var confirmLabel: String {
        isLastQuestion ? String(localized: "Confirm") : String(localized: "Next question")
    }

    // MARK: - Selection / submit logic

    private var isLastQuestion: Bool { currentIndex >= questions.count - 1 }

    private func isOptionSelected(question q: Question, index: Int) -> Bool {
        if q.multiSelect {
            return multiSelectIndices.contains(index)
        }
        return singleSelectIndex == index
    }

    private var confirmEnabled: Bool {
        guard let q = current else { return false }
        if q.multiSelect {
            return !multiSelectIndices.isEmpty || (otherActive && !trimmedOther.isEmpty)
        }
        if singleSelectIndex != nil { return true }
        return otherActive && !trimmedOther.isEmpty
    }

    private func handleOptionTap(question q: Question, index: Int) {
        if q.multiSelect {
            if multiSelectIndices.contains(index) {
                multiSelectIndices.remove(index)
            } else {
                multiSelectIndices.insert(index)
            }
            return
        }
        // Single-select: pick the option and clear any Other state so
        // the answer slots stay mutually exclusive.
        singleSelectIndex = index
        otherActive = false
        otherEditing = false
        otherFocused = false
        otherText = ""
    }

    private func handleConfirm() {
        guard let q = current else { return }
        let answer = composedAnswer(for: q)
        guard !answer.isEmpty else { return }
        commitAnswer(question: q, answer: answer)
    }

    private func composedAnswer(for q: Question) -> String {
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

    private func commitAnswer(question q: Question, answer: String) {
        answers[q.question] = answer
        if isLastQuestion {
            onSubmit(buildUpdatedInput())
            return
        }
        withAnimation {
            currentIndex += 1
            resetPerQuestionState()
        }
    }

    private func goBack() {
        guard currentIndex > 0 else { return }
        withAnimation {
            currentIndex -= 1
            resetPerQuestionState()
        }
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
    }

    private func resetPerQuestionState() {
        singleSelectIndex = nil
        multiSelectIndices = []
        otherText = ""
        otherActive = false
        otherEditing = false
        otherFocused = false
    }

    private func buildUpdatedInput() -> [String: Any] {
        var payload: [String: Any] = [:]
        if let raw = request.rawInput["questions"] { payload["questions"] = raw }
        payload["answers"] = answers
        return payload
    }

    // MARK: - Esc shortcut

    /// Zero-size button so `.keyboardShortcut(.cancelAction)` routes
    /// to `onCancel` even when the TextField doesn't hold focus.
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
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Claude wants to ask you a question"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Text(String(localized: "No questions were provided. Cancel to dismiss."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                PermissionDecisionButton(
                    title: String(localized: "Cancel"),
                    role: .destructive,
                    action: onCancel)
                Spacer(minLength: 0)
            }
        }
        .background(escapeKeyCapture)
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

/// Full-width row look shared by every option row and the collapsed
/// Other row. Fill darkens on hover; selected pulls in the accent
/// fill + stroke. No press-deflate scale — the row hugs its location
/// even while the user is mid-click.
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
    .frame(width: 600, height: 560)
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
    .frame(width: 600, height: 560)
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
    .frame(width: 600, height: 560)
    .background(Color(nsColor: .windowBackgroundColor))
}
