import AgentSDK
import AppKit
import Observation

/// AppKit replacement for `PermissionModePicker.swift` (migration plan §4.2).
/// Footer-row trigger that opens the permission-mode popover; reads the current
/// selection from the session and writes back via `setPermissionMode` (no local
/// copy). The trigger label is the mode's `shortTitle`, tinted with
/// `triggerTintColor`.
///
/// Write-back is a ONE-SHOT GUARD, not a display loop (§4.2-2, R9):
/// `seedFromDefaultsIfNeeded` runs on `rebind` AND on the `supportsAuto
/// false→true` transition (observed via the catalog keys), with the idempotent
/// guard re-checked after any write. The always-on trigger observation only
/// re-resolves the label / `auto`-row visibility — it never echoes a write back
/// into the same observation.
///
/// Injection seam for tests: `defaultsStore` defaults to
/// `NewSessionDefaultsStore.shared` (a process cache, kept per the root
/// CLAUDE.md non-goal) but can be injected with a fresh in-memory suite so the
/// seed test is parallel-safe.
@MainActor
final class PermissionModePickerController: ChromePickerController {

    /// The defaults store the draft seed writes/reads. `.shared` in production.
    private let defaultsStore: NewSessionDefaultsStore
    /// The model store the active-model resolution falls back to. `.shared` in
    /// production; injectable so the seed/auto-gating tests don't race.
    private let modelStore: ModelStore

    private let triggerLabel = NSTextField(labelWithString: "")

    private var triggerObservationActive = false

    init(
        defaultsStore: NewSessionDefaultsStore = .shared,
        modelStore: ModelStore = .shared
    ) {
        self.defaultsStore = defaultsStore
        self.modelStore = modelStore
        super.init()
        triggerLabel.font = ChromeButton.labelFont
        button.contentStack.addArrangedSubview(triggerLabel)
    }

    nonisolated deinit {}

    // MARK: - Active model (mirrors InputBarSessionChrome.activeModel)

    /// Resolves `session.model` to the matching `ModelInfo` from the per-session
    /// catalog (preferred) or the cross-launch `ModelStore` cache. nil when no
    /// model picked yet OR catalog hasn't arrived — gates the `auto` row.
    private var activeModel: ModelInfo? {
        guard let session = boundSession, let value = session.model else { return nil }
        let live = session.availableModels
        let base = live.isEmpty ? modelStore.models : live
        let pool = ModelStore.withExtendedModels(base)
        return pool.first(where: { $0.value == value })
    }

    // MARK: - Rebind (one-shot seed + re-arm)

    override func boundSessionChanged() {
        guard let session = boundSession else { return }
        // One-shot seed on rebind (§4.2-2).
        seedFromDefaultsIfNeeded()
        refreshTrigger()
        startTriggerObservation(for: session)
    }

    override func cancelTriggerObservation() {
        triggerObservationActive = false
    }

    // MARK: - Trigger label

    private func refreshTrigger() {
        guard let session = boundSession else { return }
        let mode = session.permissionMode
        triggerLabel.stringValue = mode.shortTitle
        triggerLabel.textColor = mode.triggerTintColor
        button.contentDidChange()
    }

    // MARK: - Always-on trigger observation (label + auto-row gating + seed transition)

    private func startTriggerObservation(for session: Session) {
        triggerObservationActive = true
        observeTrigger(session)
    }

    private func observeTrigger(_ session: Session) {
        withObservationTracking {
            _ = session.permissionMode
            _ = session.model
            _ = session.availableModels
            _ = modelStore.models
        } onChange: { [weak self, weak session] in
            DispatchQueue.main.async {
                guard let self, let session,
                    self.triggerObservationActive, self.boundSession === session
                else { return }
                // The catalog flipping `supportsAuto` false→true is the seed
                // transition (§4.2-2). Seed is idempotent (re-checks the guard).
                self.seedFromDefaultsIfNeeded()
                self.refreshTrigger()
                self.observeTrigger(session)
            }
        }
    }

    // MARK: - One-shot seed (verbatim guard from PermissionModePicker.seedFromDefaultsIfNeeded)

    private func seedFromDefaultsIfNeeded() {
        guard let session = boundSession,
            session.draft != nil,
            session.permissionMode == .default,
            let saved = defaultsStore.permissionMode,
            saved != .default
        else { return }
        // Auto mode is model-gated — don't seed it when the active model doesn't
        // advertise support (the popover would hide it anyway).
        if saved == .auto, activeModel?.supportsAutoMode != true { return }
        session.setPermissionMode(saved)
    }

    // MARK: - Visible modes (verbatim from PermissionModePicker.visibleModes)

    static func visibleModes(for model: ModelInfo?) -> [PermissionMode] {
        let supportsAuto = model?.supportsAutoMode == true
        return PermissionMode.allCases.filter { mode in
            mode != .auto || supportsAuto
        }
    }

    // MARK: - Popover content

    override func makePopoverContentViewController() -> NSViewController {
        let vc = PopoverScrollContentViewController(width: PopoverListMetrics.width)
        vc.loadViewIfNeeded()
        guard let session = boundSession else { return vc }
        var rows: [NSView] = []
        // Section header "Mode" — NOT localized (PermissionModePicker.swift:93).
        rows.append(PopoverSectionHeaderView(title: "Mode"))
        let selected = session.permissionMode
        for mode in Self.visibleModes(for: activeModel) {
            rows.append(
                PopoverRowView(
                    title: mode.title,
                    isSelected: mode == selected,
                    onSelect: { [weak self] in self?.selectMode(mode) }))
        }
        vc.populate(rows)
        return vc
    }

    /// onSelect: setPermissionMode, persist to NewSessionDefaultsStore for
    /// drafts, close (PermissionModePicker.swift:28-34).
    func selectMode(_ mode: PermissionMode) {
        guard let session = boundSession else { return }
        session.setPermissionMode(mode)
        if session.draft != nil {
            defaultsStore.setPermissionMode(mode)
        }
        refreshTrigger()
        closePopover()
    }

    private func closePopover() {
        toggle()  // toggle from shown → closed
    }

    // MARK: - Test-observation points

    /// The trigger's currently-rendered short title (e.g. "Ask"). Read by the
    /// labels-literal test + the seed test.
    var triggerTitleForTest: String { triggerLabel.stringValue }
}
