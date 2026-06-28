import AppKit

/// The auto-injected "Other" row at the bottom of every AskUserQuestion
/// question (migration plan §4.5). The AppKit replacement for the SwiftUI
/// `otherRow` / `otherButtonRow` / `otherEditingRow`
/// (`PermissionAskUserQuestionCardBody.swift:223-300`).
///
/// Two forms that both render at exactly `AskUserQuestionLayout.rowHeight`
/// (36pt) — collapsed shows a labelled button (`AskOptionRowView`-equivalent,
/// with ✓ when Other is active); editing swaps in an inline `NSTextField`. The
/// swap is a subview show/hide at a fixed height, so the row never jumps
/// (`:225-227`). The row is a STABLE identity across model text changes — it is
/// reconciled in place (`applyState` / `reconcileCollapsedLabel`), never rebuilt
/// per keystroke (parity blocker: the SwiftUI `TextField(text: $otherText)` was
/// one persistent view).
///
/// Interaction is funnelled through closures the wizard VC wires to the model:
/// - `onEngage` — collapsed-row tap → reveal the field (the VC makes it first
///   responder SYNCHRONOUSLY, §4.5-3).
/// - `onTextChanged(String)` — `controlTextDidChange` (`:280-282`).
/// - `onBlur` — the field resigned first responder (`:283-287`).
/// - `onSubmit` — Enter-while-editing (`insertNewline:`) — the VC blurs then
///   confirms via the single `confirm()` source of truth (§4.5-2). Return during
///   an active IME composition commits the composition and does NOT submit.
/// - `onCancel` — Esc (`cancelOperation:`) while the field edits → cancel the
///   whole wizard, matching the SwiftUI focus-independent `.cancelAction`
///   (the field editor would otherwise swallow Esc before it reached the
///   wizard root, §4.5-1).
@MainActor
final class AskOtherRowView: NSView, NSTextFieldDelegate {

    // MARK: - Callbacks (wired by the VC to the model)

    var onEngage: (() -> Void)?
    var onTextChanged: ((String) -> Void)?
    var onBlur: (() -> Void)?
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    // MARK: - Subviews

    /// The collapsed (button) form — its own `AskOptionRowView` so the look
    /// (hover/selected fill + stroke + trailing ✓) matches the option rows.
    private var collapsedRow: AskOptionRowView
    /// The editing form — an accent-tinted rounded field.
    private let editingContainer = NSView()
    private let textField = NSTextField()
    private let editFillLayer = CALayer()
    private let editStrokeLayer = CAShapeLayer()

    // MARK: - State

    private(set) var isEditing = false
    /// Set while the VC is deliberately collapsing the field (submit / blur
    /// reconcile), so the field editor's end-editing notification doesn't
    /// re-fire `onBlur` re-entrantly (timing finding: resigning the field
    /// editor mid-collapse). Mirrors `InputBarController.isApplyingProgrammaticText`.
    private var isCollapsingProgrammatically = false

    // MARK: - Init

    /// - Parameters:
    ///   - typedText: the current Other text (shown in the collapsed label when
    ///     non-empty, else "Other").
    ///   - active: whether Other is part of the answer (shows the ✓).
    ///   - editing: whether the editing field is shown.
    init(typedText: String, active: Bool, editing: Bool) {
        let trimmed = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsedLabel =
            trimmed.isEmpty ? String(localized: "Other") : typedText
        collapsedRow = AskOptionRowView(label: collapsedLabel, description: nil, selected: active)
        self.isEditing = editing
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Collapsed form pinned to all four edges.
        collapsedRow.onTap = { [weak self] in self?.onEngage?() }
        addSubview(collapsedRow)
        NSLayoutConstraint.activate([
            collapsedRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            collapsedRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            collapsedRow.topAnchor.constraint(equalTo: topAnchor),
            collapsedRow.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Editing container — accent-tinted rounded field (`:272-298`).
        editingContainer.wantsLayer = true
        editingContainer.translatesAutoresizingMaskIntoConstraints = false
        editFillLayer.cornerCurve = .continuous
        editFillLayer.cornerRadius = AskUserQuestionLayout.rowCornerRadius
        editFillLayer.masksToBounds = true
        editingContainer.layer?.addSublayer(editFillLayer)
        editStrokeLayer.fillColor = nil
        editStrokeLayer.lineWidth = 1
        editingContainer.layer?.addSublayer(editStrokeLayer)

        textField.placeholderString = String(localized: "Type your own answer…")  // `:273`
        textField.font = .systemFont(ofSize: AskUserQuestionLayout.optionLabelSize)  // size 13 `:277`
        textField.textColor = .labelColor
        // Seed the field with the in-flight Other text so a rebuild that
        // re-enters the editing form shows what the user already typed (parity
        // blocker: SwiftUI's `TextField(text: $otherText)` always reflected the
        // bound text; an empty rebuilt field would silently lose it).
        textField.stringValue = typedText
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.bezelStyle = .roundedBezel
        textField.delegate = self
        textField.translatesAutoresizingMaskIntoConstraints = false
        editingContainer.addSubview(textField)

        addSubview(editingContainer)
        NSLayoutConstraint.activate([
            editingContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            editingContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            editingContainer.topAnchor.constraint(equalTo: topAnchor),
            editingContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: AskUserQuestionLayout.rowHeight),
            textField.leadingAnchor.constraint(
                equalTo: editingContainer.leadingAnchor,
                constant: AskUserQuestionLayout.rowHPadding),
            textField.trailingAnchor.constraint(
                equalTo: editingContainer.trailingAnchor,
                constant: -AskUserQuestionLayout.rowHPadding),
            textField.centerYAnchor.constraint(equalTo: editingContainer.centerYAnchor),
        ])

        applyEditingColors()
        applyState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// macOS 26 SDK workaround: an empty `nonisolated deinit`.
    nonisolated deinit {}

    // MARK: - Test-observation points (read-only; not consumed in production)

    /// The editing text field (so the VC can `makeFirstResponder` it and tests
    /// can assert it is the window's first responder).
    var editingField: NSTextField { textField }
    var isShowingEditingField: Bool { !editingContainer.isHidden }

    // MARK: - In-place reconcile (parity blocker — no per-keystroke rebuild)

    /// Collapse the editing field back to the button form WITHOUT a full rebuild
    /// and WITHOUT re-firing `onBlur` re-entrantly. Used by the VC on
    /// Enter-while-editing (submit). Resigning the field editor here would
    /// otherwise fire `controlTextDidEndEditing` → `onBlur`; the
    /// `isCollapsingProgrammatically` guard suppresses that so the caller owns
    /// the model transition (timing finding: reentrant field-editor teardown).
    func collapseForSubmit() {
        guard isEditing else { return }
        isCollapsingProgrammatically = true
        if window?.firstResponder === textField.currentEditor() {
            window?.makeFirstResponder(window?.contentView)
        }
        isEditing = false
        applyState()
        isCollapsingProgrammatically = false
    }

    /// Update the collapsed button's label + ✓ in place (so a pure text /
    /// active change never recreates the row). The collapsed label shows the
    /// typed text when non-empty, else "Other".
    func reconcileCollapsed(typedText: String, active: Bool) {
        let trimmed = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        collapsedRow.setLabel(trimmed.isEmpty ? String(localized: "Other") : typedText)
        collapsedRow.isSelected = active
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let bounds = editingContainer.bounds
        editFillLayer.frame = bounds
        editStrokeLayer.frame = bounds
        if bounds.width > 0, bounds.height > 0 {
            let inset: CGFloat = 0.5
            editStrokeLayer.path = BarSurfaceMask.continuousRoundedPath(
                in: bounds.insetBy(dx: inset, dy: inset),
                cornerRadius: AskUserQuestionLayout.rowCornerRadius - inset)
        } else {
            editStrokeLayer.path = nil
        }
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyEditingColors()
    }

    /// Accent fill 0.12 + stroke 0.55 (`:291-298`), re-resolved against the
    /// current appearance and wrapped in a disabled transaction (R14).
    private func applyEditingColors() {
        var fill: CGColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        var stroke: CGColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            stroke = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        editFillLayer.backgroundColor = fill
        editStrokeLayer.strokeColor = stroke
        CATransaction.commit()
    }

    private func applyState() {
        editingContainer.isHidden = !isEditing
        collapsedRow.isHidden = isEditing
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        onTextChanged?(textField.stringValue)
    }

    /// The field lost first responder (the user moved focus elsewhere). Collapse
    /// (`:283-287`). Suppressed while the VC is collapsing programmatically
    /// (submit) so the field-editor resign doesn't re-fire `onBlur` re-entrantly
    /// (timing finding: reentrant teardown inside `controlTextDidEndEditing`).
    func controlTextDidEndEditing(_ obj: Notification) {
        // Only fire blur if we're still in the editing form AND this is a
        // genuine user-driven focus change — the VC may have already collapsed
        // us (submit), which resigns the field.
        guard isEditing, !isCollapsingProgrammatically else { return }
        onBlur?()
    }

    /// Enter-while-editing-Other (§4.5-2) and Esc-while-editing (§4.5-1).
    /// `insertNewline:` blurs the field and confirms via the single `confirm()`
    /// source of truth — but ONLY when there is no active IME composition
    /// (Return during composition commits the composition and must NOT advance).
    /// `cancelOperation:` routes Esc to `onCancel` so the wizard cancels even
    /// while the Other field holds first responder (the field editor would
    /// otherwise swallow Esc before it reached the wizard root, matching the
    /// SwiftUI focus-independent `.cancelAction`). The marked-text guard reads
    /// the field's editor live.
    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Return during an active IME composition commits the composition,
            // does NOT advance (§4.5-2). The marked range is non-empty mid-IME.
            if textView.hasMarkedText() {
                return false  // let the field commit the composition
            }
            onSubmit?()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Esc while editing Other → cancel the wizard (focus-independent,
            // §4.5-1). Without this the field editor consumes Esc (abort
            // editing) and the wizard root never sees it.
            onCancel?()
            return true
        }
        return false
    }
}
