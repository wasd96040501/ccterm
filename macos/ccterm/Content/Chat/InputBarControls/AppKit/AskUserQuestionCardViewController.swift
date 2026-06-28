import AgentSDK
import AppKit

/// The AskUserQuestion wizard (migration plan §4.5) — a dedicated
/// `NSViewController` that owns the `AskUserQuestionModel` state machine and the
/// full card chrome (question header + option rows + Other row + Cancel/Confirm
/// row). AppKit replacement for the SwiftUI `PermissionAskUserQuestionCardBody`.
///
/// `PermissionCardContentView` renders NO generic chrome for `askUserQuestion`
/// (`bodyOwnsChrome`); it mounts this VC's `view` as its sole body section and
/// retains the VC. Reuses the shared AppKit `PermissionDecisionButtonView`
/// (ported in Phase 2a) for the Cancel / Confirm row.
///
/// **State machine.** All decode / answer / nav logic lives in
/// `AskUserQuestionModel` (SwiftUI-free, lifted verbatim). The VC sets
/// `model.onChange = rebuildForCurrentQuestion` so every model mutation rebuilds
/// the arranged subviews — the AppKit analogue of SwiftUI body re-eval. The VC
/// itself owns ONLY the first-responder choreography (the model deliberately
/// holds no `@FocusState`, §4.5-3).
///
/// **Focus (§4.5-1, R4).** On `viewDidAppear` (window-gated) the wizard root
/// takes first responder; `cancelOperation(_:)` → `model.cancel()` (Esc, focus-
/// dependent now); Return at the root → `confirm()` (the window default-button
/// keyEquivalent analogue). The Other text field is the only other contender,
/// both wizard-owned, both moved SYNCHRONOUSLY (no async makeFirstResponder).
/// On dismiss the card controller restores focus to the transcript
/// (`makeFirstResponder(nil)`, D6).
///
/// **Single `confirm()` source of truth (§4.5-2).** Button click / root-Return /
/// Other-field-newline all funnel to `confirm()`. Enter while editing Other
/// blurs the field (collapse) then confirms; Return during IME composition
/// commits the composition and does NOT advance (guarded in `AskOtherRowView`).
///
/// **Height containment (§4.5-4, R1).** The VC's `view` overrides
/// `intrinsicContentSize = .zero` and pins its content stack to its own four
/// edges; the card controller pins the card bottom + leading/trailing (centered,
/// width-capped) with NO top constraint, so per-question growth flows upward
/// into the host's slack and never pumps the resting bar.
///
/// **Teardown (§4.5-5).** No `NSEvent` monitor is used (Esc/Enter go through
/// `cancelOperation`/`keyDown` on the focused root). `prepareForRemoval()`
/// clears the model callback so a late rebuild can't fire after the card is
/// gone. The card controller removes the host and restores first responder.
@MainActor
final class AskUserQuestionCardViewController: NSViewController {

    // MARK: - Model

    let model: AskUserQuestionModel

    // MARK: - Subviews

    private let contentStack = NSStackView()
    /// The vertical stack of option rows + the Other row (rebuilt per question).
    private let optionsStack = NSStackView()
    private var headerView: AskQuestionHeaderView?
    private var otherRow: AskOtherRowView?
    private var optionRows: [AskOptionRowView] = []
    private var confirmButton: PermissionDecisionButtonView?
    private var cancelButton: PermissionDecisionButtonView?

    // MARK: - Init

    /// Production initializer. Tests drive this exact entry point + the model's
    /// public action seams — no test-only seam.
    init(
        request: PermissionRequest,
        onSubmit: @escaping ([String: Any]?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.model = AskUserQuestionModel(
            request: request, onSubmit: onSubmit, onCancel: onCancel)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// macOS 26 SDK workaround: an empty `nonisolated deinit`.
    nonisolated deinit {}

    // MARK: - View

    override func loadView() {
        let root = WizardRootView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.onCancel = { [weak self] in self?.model.cancel() }
        root.onReturn = { [weak self] in self?.confirm() }
        // Window-arrival retry (§4.5-1 / R4): a card mounted BEFORE its host is
        // windowed (a session swap can reconcile the card in a source phase
        // before the full-pane host joins a window) would never acquire focus
        // — `viewDidAppear`'s `makeFirstResponder` is a silent no-op without a
        // window. The root re-fires focus acquisition when the window arrives,
        // mirroring `InputBarController`'s window-gated deferred autofocus.
        root.onWindowArrived = { [weak self] in self?.acquireFocusIfNeeded() }
        self.view = root

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = AskUserQuestionLayout.groupSpacing  // `:49,98`
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: root.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        optionsStack.orientation = .vertical
        optionsStack.alignment = .leading
        optionsStack.spacing = AskUserQuestionLayout.rowSpacing  // `:48,186`
        optionsStack.translatesAutoresizingMaskIntoConstraints = false

        // Wire the model callbacks BEFORE the first rebuild so subsequent
        // mutations reconcile (the initial build runs unconditionally below).
        // `onChange` = structural rebuild (option pick, engage/collapse, nav);
        // `onOtherTextChanged` = lightweight in-place reconcile (NO rebuild —
        // a per-keystroke rebuild would destroy the live, focused field, parity
        // blocker).
        model.onChange = { [weak self] in self?.rebuildForCurrentQuestion() }
        model.onOtherTextChanged = { [weak self] in self?.reconcileOtherTextInPlace() }
        rebuildForCurrentQuestion()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        acquireFocusIfNeeded()
    }

    /// Take first responder so Esc (`cancelOperation`) / Return reach the wizard
    /// root (§4.5-1). Window-gated (a `makeFirstResponder` before the host is in
    /// a window is a silent no-op) and idempotent — does NOT steal focus from a
    /// wizard-owned responder that already has it (the Other field while
    /// editing). Called from `viewDidAppear` (mount with a live window) AND from
    /// the root's `viewDidMoveToWindow` (a card mounted before its host joined a
    /// window, §4.5-1 / R4). The card controller has already resigned the input
    /// bar synchronously on mount.
    private func acquireFocusIfNeeded() {
        guard let window = view.window else { return }
        let current = window.firstResponder
        // Already on the wizard root → nothing to do.
        if current === view { return }
        // The Other field is editing and holds focus → don't steal it (§4.5-3).
        if model.otherEditing, let other = otherRow,
            current === other.editingField.currentEditor()
        {
            return
        }
        window.makeFirstResponder(view)
    }

    /// Wired into the card teardown chain (§4.5-5). Drop the model callbacks so
    /// a late rebuild / reconcile can't fire after the host is gone; nothing
    /// else to cancel (no monitor / timer / async work).
    func prepareForRemoval() {
        model.onChange = nil
        model.onOtherTextChanged = nil
    }

    // MARK: - Rebuild (AppKit analogue of SwiftUI body re-eval)

    /// Rebuild the arranged subviews for the current question — header chips +
    /// option rows + Other row + Cancel/Confirm. Called after EVERY model
    /// mutation. Also reconciles the Other field's first-responder ownership off
    /// the model's `otherEditing` flag (SYNCHRONOUS, §4.5-3).
    func rebuildForCurrentQuestion() {
        // Tear down the previous question's views.
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        optionsStack.arrangedSubviews.forEach {
            optionsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        optionRows = []
        headerView = nil
        otherRow = nil
        confirmButton = nil
        cancelButton = nil

        guard let q = model.current else {
            buildFallback()
            return
        }

        // Header.
        let header = AskQuestionHeaderView(
            questionText: q.question, headerText: q.header,
            index: model.currentIndex, total: model.questions.count)
        header.onBack = { [weak self] in self?.model.goBack() }
        headerView = header
        contentStack.addArrangedSubview(header)
        header.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor).isActive = true
        header.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor).isActive = true

        // Options + Other.
        for (idx, opt) in q.options.enumerated() {
            let row = AskOptionRowView(
                label: opt.label, description: opt.description,
                selected: model.isOptionSelected(index: idx))
            row.onTap = { [weak self] in self?.model.selectOption(idx) }
            optionRows.append(row)
            optionsStack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: optionsStack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: optionsStack.trailingAnchor).isActive = true
        }

        let other = AskOtherRowView(
            typedText: model.otherText, active: model.otherActive, editing: model.otherEditing)
        other.onEngage = { [weak self] in self?.model.engageOther() }
        other.onTextChanged = { [weak self] text in self?.model.commitOtherText(text) }
        other.onBlur = { [weak self] in self?.model.endOtherEditing() }
        other.onSubmit = { [weak self] in self?.submitFromOtherField() }
        other.onCancel = { [weak self] in self?.model.cancel() }
        otherRow = other
        optionsStack.addArrangedSubview(other)
        other.leadingAnchor.constraint(equalTo: optionsStack.leadingAnchor).isActive = true
        other.trailingAnchor.constraint(equalTo: optionsStack.trailingAnchor).isActive = true

        contentStack.addArrangedSubview(optionsStack)
        optionsStack.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor).isActive = true
        optionsStack.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor).isActive =
            true

        // Decision row.
        let decisionRow = makeDecisionRow()
        contentStack.addArrangedSubview(decisionRow)
        decisionRow.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor).isActive = true
        decisionRow.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor).isActive = true

        reconcileConfirm()
        reconcileOtherFocus()
    }

    /// In-place reconcile for a PURE Other text change (`model.onOtherTextChanged`
    /// → `commitOtherText`). Updates ONLY the Confirm-enable state and the
    /// collapsed Other label/✓ — it does NOT touch the editing field nor rebuild
    /// any rows, so the user's caret + in-flight composition survive every
    /// keystroke (parity blocker). The editing field's `stringValue` is the
    /// source of truth while it is first responder; we never write back to it.
    private func reconcileOtherTextInPlace() {
        reconcileConfirm()
        // Keep the collapsed button's label/✓ current so toggling back to the
        // collapsed form (blur) shows the typed text without a rebuild.
        otherRow?.reconcileCollapsed(typedText: model.otherText, active: model.otherActive)
    }

    private func makeDecisionRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = AskUserQuestionLayout.chipRowSpacing  // 8 (`:314`)
        row.translatesAutoresizingMaskIntoConstraints = false

        let cancel = PermissionDecisionButtonView(
            title: String(localized: "Cancel"), role: .destructive,
            onClick: { [weak self] in self?.model.cancel() })
        cancel.setContentHuggingPriority(.required, for: .horizontal)
        cancelButton = cancel

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let confirm = PermissionDecisionButtonView(
            title: model.confirmLabel, role: .primary,
            onClick: { [weak self] in self?.confirm() })
        confirm.setContentHuggingPriority(.required, for: .horizontal)
        confirmButton = confirm

        row.addArrangedSubview(cancel)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(confirm)
        return row
    }

    // MARK: - Confirm (single source of truth, §4.5-2)

    private func confirm() {
        guard model.confirmEnabled else { return }
        model.confirm()
    }

    /// Enter-while-editing-Other (§4.5-2): collapse the field (NO re-entrant
    /// rebuild — `collapseForSubmit` resigns the field editor with the blur
    /// notification suppressed so it doesn't fire `endOtherEditing → onChange`
    /// while the field editor's own end-editing notification is mid-dispatch,
    /// timing finding) then confirm via the single `confirm()` source of truth.
    /// The model already carries the latest `otherText` (every keystroke went
    /// through `commitOtherText`), so `confirm()` reads a consistent answer.
    private func submitFromOtherField() {
        otherRow?.collapseForSubmit()
        // The Other row stays active (the model's `otherActive`/`otherText` are
        // unchanged); fold the collapse into the model so subsequent state reads
        // are consistent without a rebuild.
        if model.otherEditing { model.endOtherEditing() }
        // Hand first responder back to the wizard root so a subsequent Return /
        // Esc (after advancing to the next question) reaches it (`collapseForSubmit`
        // resigned the field editor without a destination). For the final
        // question this is harmless — `confirm()` submits and the card tears down.
        view.window?.makeFirstResponder(view)
        confirm()
    }

    /// Disable + dim Confirm when no answer is collectable (`:325-326`).
    private func reconcileConfirm() {
        guard let confirm = confirmButton else { return }
        let enabled = model.confirmEnabled
        confirm.isEnabled = enabled
        confirm.alphaValue = enabled ? 1 : 0.5
    }

    /// Sync the Other field's first-responder ownership with the model's
    /// `otherEditing` flag — SYNCHRONOUS (§4.5-3 forbids the async hop). Moves
    /// focus to the field only when editing AND the field doesn't already hold
    /// it — so the engage transition (and the rare structural rebuild that
    /// recreates the field while still editing, e.g. a multi-select toggle)
    /// hands focus to the freshly-built field, while a live in-progress edit
    /// (which never triggers a rebuild now that text changes reconcile in place,
    /// parity blocker) short-circuits and keeps its caret undisturbed (MINOR:
    /// focus follows the FIELD, never churns an active caret). The model never
    /// asks us to resign here (blur is user-driven through the field).
    private func reconcileOtherFocus() {
        guard model.otherEditing, let other = otherRow, view.window != nil else { return }
        if view.window?.firstResponder !== other.editingField.currentEditor() {
            view.window?.makeFirstResponder(other.editingField)
        }
    }

    // MARK: - Fallback (empty / malformed payload, `:472-492`)

    private func buildFallback() {
        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = AskUserQuestionLayout.fallbackInnerSpacing  // `:475`
        inner.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(
            labelWithString: String(localized: "Claude wants to ask you a question"))
        title.font = .systemFont(ofSize: AskUserQuestionLayout.fallbackTitleSize, weight: .medium)
        title.textColor = .labelColor
        let subtitle = NSTextField(
            wrappingLabelWithString: String(
                localized: "No questions were provided. Cancel to dismiss."))
        subtitle.font = .systemFont(ofSize: AskUserQuestionLayout.fallbackSubtitleSize)
        subtitle.textColor = .secondaryLabelColor
        inner.addArrangedSubview(title)
        inner.addArrangedSubview(subtitle)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = AskUserQuestionLayout.chipRowSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        let cancel = PermissionDecisionButtonView(
            title: String(localized: "Cancel"), role: .destructive,
            onClick: { [weak self] in self?.model.cancel() })
        cancel.setContentHuggingPriority(.required, for: .horizontal)
        cancelButton = cancel
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(cancel)
        row.addArrangedSubview(spacer)

        contentStack.addArrangedSubview(inner)
        inner.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor).isActive = true
        inner.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor).isActive = true
        contentStack.addArrangedSubview(row)
        row.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor).isActive = true
        row.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor).isActive = true
    }

    // MARK: - Test-observation points (read-only; not consumed in production)

    var headerForTesting: AskQuestionHeaderView? { headerView }
    var optionRowsForTesting: [AskOptionRowView] { optionRows }
    var otherRowForTesting: AskOtherRowView? { otherRow }
    var confirmButtonForTesting: PermissionDecisionButtonView? { confirmButton }
    var cancelButtonForTesting: PermissionDecisionButtonView? { cancelButton }

    // MARK: - Wizard root view

    /// The wizard's root view. Regime-A `intrinsicContentSize = .zero` so the
    /// content's per-question growth can't leak up to the full-pane host (R1).
    /// Holds first responder so `cancelOperation` (Esc) and Return reach the
    /// wizard (§4.5-1).
    private final class WizardRootView: NSView {
        var onCancel: (() -> Void)?
        var onReturn: (() -> Void)?
        /// Fired when the view joins a window (non-nil) so the VC can acquire
        /// first responder for a card mounted before its host was windowed
        /// (§4.5-1 / R4). `viewDidAppear`'s `makeFirstResponder` is a silent
        /// no-op pre-window; this is the deferred retry.
        var onWindowArrived: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { .zero }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { onWindowArrived?() }
        }

        /// Esc — focus-dependent now (§4.5-1). Works in the fallback branch too
        /// (the root holds first responder regardless of which sub-form is up).
        override func cancelOperation(_ sender: Any?) {
            onCancel?()
        }

        /// Return at the root → confirm (the window default-button keyEquivalent
        /// analogue, §4.5-1). `keyCode 36` = Return, `76` = keypad Enter.
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36 || event.keyCode == 76 {
                onReturn?()
                return
            }
            super.keyDown(with: event)
        }

        /// macOS 26 SDK workaround: an empty `nonisolated deinit`.
        nonisolated deinit {}
    }
}
