import AgentSDK
import AppKit
import Observation

/// AppKit replacement for `ModelEffortPicker.swift` (migration plan §4.2).
/// Footer-row trigger opening a stacked Models + Effort + Fast-mode popover.
/// Reads from the session, writes back via `setModel` / `setEffort` /
/// `setFastMode`. The entire trigger is HIDDEN when `visibleModels.isEmpty`
/// (§4.2 — the row toggles its arranged-subview `isHidden`, height-invariant).
///
/// Write-back is a ONE-SHOT GUARD (§4.2-2, R9): `backfillModelIfNeeded` runs on
/// `rebind` AND on the catalog-first-arrival transition (observed via the
/// catalog keys), idempotent guard re-checked after the write. The always-on
/// observation only re-resolves the label / visibility / loading spinner — it
/// never echoes a write back into the same observation.
///
/// `.ultracode` skip-persist (§4.2-7): `activeEffortLevels` appends `.ultracode`
/// for xhigh-capable models; `onSelectEffort` persists to `EffortDefaultStore`
/// ONLY when `effort != .ultracode`.
///
/// Injection seam for tests: `effortStore` / `defaultsStore` / `modelStore`
/// default to the `.shared` process caches but accept a fresh in-memory suite
/// so the backfill / `.ultracode` tests are parallel-safe.
@MainActor
final class ModelEffortPickerController: ChromePickerController {

    private let effortStore: EffortDefaultStore
    private let defaultsStore: NewSessionDefaultsStore
    private let modelStore: ModelStore

    /// Trigger label: "model · effort" (model primary, "·" + effort secondary).
    private let modelLabel = NSTextField(labelWithString: "")
    private let dotLabel = NSTextField(labelWithString: "·")
    private let effortLabel = NSTextField(labelWithString: "")
    /// Mini spinner shown next to the trigger while ModelStore is loading
    /// (`ModelEffortPicker.swift:81-86`).
    private let loadingSpinner = NSProgressIndicator()

    private var triggerObservationActive = false

    init(
        effortStore: EffortDefaultStore = .shared,
        defaultsStore: NewSessionDefaultsStore = .shared,
        modelStore: ModelStore = .shared
    ) {
        self.effortStore = effortStore
        self.defaultsStore = defaultsStore
        self.modelStore = modelStore
        super.init()

        modelLabel.font = ChromeButton.labelFont
        modelLabel.textColor = .labelColor
        dotLabel.font = ChromeButton.labelFont
        dotLabel.textColor = .secondaryLabelColor
        effortLabel.font = ChromeButton.labelFont
        effortLabel.textColor = .secondaryLabelColor

        button.contentStack.addArrangedSubview(modelLabel)
        button.contentStack.addArrangedSubview(dotLabel)
        button.contentStack.addArrangedSubview(effortLabel)
    }

    nonisolated deinit {}

    // MARK: - Visible models (verbatim from ModelEffortPicker.visibleModels)

    private var visibleModels: [ModelInfo] {
        let live = boundSession?.availableModels ?? []
        let base = live.isEmpty ? modelStore.models : live
        return ModelStore.withExtendedModels(base)
    }

    private var selectedModelInfo: ModelInfo? {
        guard let value = boundSession?.model else { return nil }
        return visibleModels.first(where: { $0.value == value })
    }

    /// Effort to show as selected (verbatim from `ModelEffortPicker.effectiveEffort`).
    private var effectiveEffort: Effort? {
        if let effort = boundSession?.effort { return effort }
        guard let info = selectedModelInfo else { return nil }
        return effortStore.effort(for: info)
    }

    // MARK: - Rebind (one-shot backfill + re-arm)

    override func boundSessionChanged() {
        guard let session = boundSession else { return }
        backfillModelIfNeeded()
        refreshTrigger()
        startTriggerObservation(for: session)
    }

    override func cancelTriggerObservation() {
        triggerObservationActive = false
    }

    // MARK: - Trigger

    private func refreshTrigger() {
        // Hide the entire trigger until a catalog is available (§4.2 — the row
        // toggles `isHidden`, height-invariant).
        let hidden = visibleModels.isEmpty
        button.isHidden = hidden
        if hidden { return }

        modelLabel.stringValue = boundSession?.model ?? "Model"
        if let effort = effectiveEffort {
            dotLabel.isHidden = false
            effortLabel.isHidden = false
            effortLabel.stringValue = effort.title
        } else {
            dotLabel.isHidden = true
            effortLabel.isHidden = true
        }
        // Loading spinner next to the trigger while the catalog fetches.
        updateLoadingSpinner()
        button.contentDidChange()
    }

    private func updateLoadingSpinner() {
        if modelStore.isLoading {
            if loadingSpinner.superview == nil {
                loadingSpinner.style = .spinning
                loadingSpinner.controlSize = .small
                loadingSpinner.isIndeterminate = true
                loadingSpinner.setAccessibilityLabel("Loading models")
                button.contentStack.addArrangedSubview(loadingSpinner)
            }
            loadingSpinner.isHidden = false
            loadingSpinner.startAnimation(nil)
        } else {
            loadingSpinner.stopAnimation(nil)
            loadingSpinner.isHidden = true
        }
    }

    // MARK: - Always-on observation (label/visibility/spinner + backfill transition)

    private func startTriggerObservation(for session: Session) {
        triggerObservationActive = true
        observeTrigger(session)
    }

    private func observeTrigger(_ session: Session) {
        withObservationTracking {
            _ = session.model
            _ = session.effort
            _ = session.availableModels
            _ = modelStore.models
            _ = modelStore.isLoading
        } onChange: { [weak self, weak session] in
            DispatchQueue.main.async {
                guard let self, let session,
                    self.triggerObservationActive, self.boundSession === session
                else { return }
                // Catalog-first-arrival is the backfill transition (§4.2-2);
                // backfill re-checks its idempotent guard.
                self.backfillModelIfNeeded()
                self.refreshTrigger()
                self.observeTrigger(session)
            }
        }
    }

    // MARK: - One-shot backfill (verbatim from ModelEffortPicker.backfillModelIfNeeded)

    private func backfillModelIfNeeded() {
        guard let session = boundSession,
            session.model == nil, let first = visibleModels.first
        else { return }
        let preferred: ModelInfo
        if session.draft != nil,
            let saved = defaultsStore.model,
            let match = visibleModels.first(where: { $0.value == saved })
        {
            preferred = match
        } else {
            preferred = first
        }
        applyModelSelection(preferred.value)
    }

    /// Switching model: write value, resolve remembered/default effort, push it
    /// (verbatim from `ModelEffortPicker.applyModelSelection`).
    private func applyModelSelection(_ value: String) {
        guard let session = boundSession else { return }
        session.setModel(value)
        guard let info = visibleModels.first(where: { $0.value == value }),
            let resolved = effortStore.effort(for: info)
        else { return }
        session.setEffort(resolved)
    }

    // MARK: - activeEffortLevels (verbatim from ModelEffortPicker)

    /// Effort levels from the active model's `supportedEffortLevels`; appends
    /// `.ultracode` when xhigh-capable. nil to hide the section.
    static func activeEffortLevels(forModelValue value: String?, models: [ModelInfo]) -> [Effort]? {
        guard let value,
            let info = models.first(where: { $0.value == value }),
            info.supportsEffort == true,
            let raw = info.supportedEffortLevels
        else { return nil }
        var mapped = raw.compactMap(Effort.init(rawValue:))
        if mapped.contains(.xhigh), !mapped.contains(.ultracode) {
            mapped.append(.ultracode)
        }
        return mapped.isEmpty ? nil : mapped
    }

    private var activeEffortLevels: [Effort]? {
        Self.activeEffortLevels(forModelValue: boundSession?.model, models: visibleModels)
    }

    // MARK: - Popover content

    override func makePopoverContentViewController() -> NSViewController {
        let vc = PopoverScrollContentViewController(width: PopoverListMetrics.width)
        vc.loadViewIfNeeded()
        guard let session = boundSession else { return vc }
        var rows: [NSView] = []

        // Models section — header "Models" (NOT localized).
        rows.append(PopoverSectionHeaderView(title: "Models"))
        let models = visibleModels
        if models.isEmpty {
            rows.append(makeLoadingModelsRow())
        } else {
            let selectedValue = session.model
            for info in models {
                rows.append(
                    ModelPopoverRowView(
                        title: info.value,
                        subtitle: info.description,
                        isSelected: info.value == selectedValue,
                        onSelect: { [weak self] in self?.selectModel(info.value) }))
            }
        }

        // Effort section (only if non-empty) — header "Effort" (NOT localized).
        if let levels = activeEffortLevels, !levels.isEmpty {
            rows.append(makeDivider())
            rows.append(PopoverSectionHeaderView(title: "Effort"))
            let selectedEffort = effectiveEffort
            for effort in levels {
                rows.append(
                    PopoverRowView(
                        title: effort.title,
                        isSelected: effort == selectedEffort,
                        onSelect: { [weak self] in self?.selectEffort(effort) }))
            }
        }

        // Fast mode section — header "Fast mode" (NOT localized).
        rows.append(makeDivider())
        rows.append(PopoverSectionHeaderView(title: "Fast mode"))
        rows.append(
            FastModeToggleRowView(
                enabled: session.fastModeEnabled,
                onToggle: { [weak self] enabled in self?.toggleFastMode(enabled) }))

        vc.populate(rows)
        return vc
    }

    private func makeLoadingModelsRow() -> NSView {
        let row = NSView()
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: String(localized: "Loading models…"))
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(spinner)
        row.addSubview(label)
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(
                equalTo: row.leadingAnchor, constant: PopoverListMetrics.horizontalInset),
            spinner.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: row.trailingAnchor, constant: -PopoverListMetrics.horizontalInset),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.topAnchor.constraint(equalTo: spinner.topAnchor, constant: -6),
            row.bottomAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 6),
        ])
        return row
    }

    private func makeDivider() -> NSView {
        let container = NSView()
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            line.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            // vertical padding 4 (ModelEffortPicker.swift:204,215).
            container.topAnchor.constraint(equalTo: line.topAnchor, constant: -4),
            container.bottomAnchor.constraint(equalTo: line.bottomAnchor, constant: 4),
        ])
        return container
    }

    // MARK: - Write-backs

    /// onSelectModel: applyModelSelection, persist for drafts, close
    /// (ModelEffortPicker.swift:59-65).
    func selectModel(_ value: String) {
        guard let session = boundSession else { return }
        applyModelSelection(value)
        if session.draft != nil {
            defaultsStore.setModel(value)
        }
        refreshTrigger()
        toggle()
    }

    /// onSelectEffort: setEffort, persist EXCEPT for `.ultracode` (the
    /// skip-persist guard, §4.2-7), close (ModelEffortPicker.swift:66-75).
    func selectEffort(_ effort: Effort) {
        guard let session = boundSession else { return }
        session.setEffort(effort)
        if effort != .ultracode, let value = session.model {
            effortStore.remember(effort, for: value)
        }
        refreshTrigger()
        toggle()
    }

    /// onToggleFastMode: setFastMode (ModelEffortPicker.swift:76-78). Stays open.
    func toggleFastMode(_ enabled: Bool) {
        boundSession?.setFastMode(enabled)
    }

    // MARK: - Test-observation points

    /// The model portion of the trigger label.
    var modelTitleForTest: String { modelLabel.stringValue }
    /// The effort portion of the trigger label ("" when hidden).
    var effortTitleForTest: String { effortLabel.isHidden ? "" : effortLabel.stringValue }
    /// Whether the entire trigger is hidden (catalog empty).
    var triggerHiddenForTest: Bool { button.isHidden }
}
