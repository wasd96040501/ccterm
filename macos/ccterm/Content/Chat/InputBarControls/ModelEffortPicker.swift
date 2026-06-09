import AgentSDK
import SwiftUI

/// Footer-row trigger that opens a stacked Models + Effort + Fast mode
/// popover. Reads the current selection from the session and writes back
/// via `setModel` / `setEffort` / `setFastMode`. The model catalog
/// streams from `ModelStore.shared`, kicked off at app launch — the
/// trigger renders a small `ProgressView` next to its label while the
/// first fetch is in flight.
///
/// Display rules (anchored to CLI `init.models[]`, no Claude.app
/// expansion): rows show the CLI `value` (raw — `default` / `sonnet` /
/// `haiku`) as the primary line and the CLI `description` as a smaller
/// secondary line. No `conciseDisplayName` rewrite, no "1M / Legacy"
/// dim suffix — the CLI is the single source of truth.
///
/// Effort defaults are per-model and persisted in `EffortDefaultStore`.
/// Switching model auto-applies the remembered effort (or the
/// first-time default — `default → xhigh`, `sonnet → high`,
/// fallback → `high`), clamped to the new model's
/// `supportedEffortLevels`.
///
/// Fast mode is always-enabled in the toggle: CLI's `init.models[]`
/// doesn't carry a `supportsFastMode` field, so we have nothing to
/// gate on; the CLI itself rejects fast-mode requests on unsupported
/// models.
struct ModelEffortPicker: View {
    let session: Session
    @State private var isPresented = false
    @State private var store = ModelStore.shared

    var body: some View {
        // Hide the entire trigger until a catalog is available. Without
        // a catalog there's no honest single source — no `default` row
        // to anchor `session.model` to, no `supportedEffortLevels` to
        // gate the effort section. Showing a placeholder "Model" pill
        // implies the user picked something they didn't.
        if visibleModels.isEmpty {
            EmptyView()
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        HStack(spacing: 6) {
            BarChromeButton(label: {
                triggerLabel
            }) {
                isPresented.toggle()
            }
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                ModelEffortPopoverContent(
                    models: visibleModels,
                    selectedModelValue: session.model,
                    selectedEffort: effectiveEffort,
                    fastModeEnabled: session.fastModeEnabled,
                    onSelectModel: { value in
                        applyModelSelection(value)
                        if session.draft != nil {
                            NewSessionDefaultsStore.shared.setModel(value)
                        }
                        isPresented = false
                    },
                    onSelectEffort: { effort in
                        session.setEffort(effort)
                        // Ultracode is a session choice, not a per-model
                        // default — and it isn't in `supportedEffortLevels`,
                        // so `EffortDefaultStore` would clamp it away anyway.
                        if effort != .ultracode, let value = session.model {
                            EffortDefaultStore.shared.remember(effort, for: value)
                        }
                        isPresented = false
                    },
                    onToggleFastMode: { enabled in
                        session.setFastMode(enabled)
                    }
                )
            }
            if store.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.85)
                    .accessibilityLabel("Loading models")
            }
        }
        .task(id: visibleModels.first?.value) {
            backfillModelIfNeeded()
        }
    }

    /// Per-session catalog wins; fall through to the app-launch
    /// `ModelStore` snapshot when the session hasn't replied yet.
    private var visibleModels: [ModelInfo] {
        let live = session.availableModels
        let base = live.isEmpty ? store.models : live
        return ModelStore.withExtendedModels(base)
    }

    private var selectedModelInfo: ModelInfo? {
        guard let value = session.model else { return nil }
        return visibleModels.first(where: { $0.value == value })
    }

    /// Single-source backfill: as soon as a catalog is available and
    /// the session hasn't recorded a model yet, write a model value back
    /// into the session. Draft sessions prefer the user's last-picked
    /// model from `NewSessionDefaultsStore` when it's still in the
    /// catalog; otherwise (and for active sessions whose record carried
    /// no model) we fall back to `visibleModels.first` — the CLI's
    /// `default` entry, head of `init.models[]`.
    private func backfillModelIfNeeded() {
        guard session.model == nil, let first = visibleModels.first else { return }
        let preferred: ModelInfo
        if session.draft != nil,
            let saved = NewSessionDefaultsStore.shared.model,
            let match = visibleModels.first(where: { $0.value == saved })
        {
            preferred = match
        } else {
            preferred = first
        }
        applyModelSelection(preferred.value)
    }

    /// Effort to show as "selected" in trigger + popover. Real
    /// `session.effort` wins; otherwise the per-model default from
    /// `EffortDefaultStore`. nil only when no model is selected or the
    /// model declares no effort support.
    private var effectiveEffort: Effort? {
        if let effort = session.effort { return effort }
        guard let info = selectedModelInfo else { return nil }
        return EffortDefaultStore.shared.effort(for: info)
    }

    /// Switching model: write the new value, then resolve the model's
    /// remembered/default effort and push it through `setEffort` so
    /// the CLI receives an effort consistent with what the UI shows.
    private func applyModelSelection(_ value: String) {
        session.setModel(value)
        guard let info = visibleModels.first(where: { $0.value == value }),
            let resolved = EffortDefaultStore.shared.effort(for: info)
        else { return }
        session.setEffort(resolved)
    }

    @ViewBuilder
    private var triggerLabel: some View {
        HStack(spacing: 4) {
            Text(session.model ?? "Model")
                .foregroundStyle(.primary)
            if let effort = effectiveEffort {
                Text("·")
                    .foregroundStyle(.secondary)
                Text(effort.title)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ModelEffortPopoverContent: View {
    let models: [ModelInfo]
    let selectedModelValue: String?
    let selectedEffort: Effort?
    let fastModeEnabled: Bool
    let onSelectModel: (String) -> Void
    let onSelectEffort: (Effort) -> Void
    let onToggleFastMode: (Bool) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Section headers mirror the CLI vocabulary and are NOT
                // localized — see PermissionMode / Effort+Display for the
                // same policy.
                PopoverSectionHeader(title: "Models")
                if models.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini).scaleEffect(0.85)
                        Text("Loading models…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, PopoverList.horizontalInset)
                    .padding(.vertical, 6)
                } else {
                    ForEach(models, id: \.value) { info in
                        ModelPopoverRow(
                            title: info.value,
                            subtitle: info.description,
                            isSelected: info.value == selectedModelValue,
                            onSelect: { onSelectModel(info.value) }
                        )
                    }
                }

                // Effort section is strictly the active model's declared
                // supportedEffortLevels (no SDK-wide fallback). When the
                // model declares zero or the model itself doesn't support
                // effort, the section is hidden.
                if let levels = activeEffortLevels, !levels.isEmpty {
                    Divider().padding(.vertical, 4)
                    PopoverSectionHeader(title: "Effort")
                    ForEach(levels, id: \.rawValue) { effort in
                        PopoverRow(
                            title: effort.title,
                            isSelected: effort == selectedEffort,
                            onSelect: { onSelectEffort(effort) }
                        )
                    }
                }

                Divider().padding(.vertical, 4)
                PopoverSectionHeader(title: "Fast mode")
                FastModeToggleRow(
                    enabled: fastModeEnabled,
                    onToggle: onToggleFastMode
                )
            }
            .padding(PopoverList.outerPadding)
        }
        // Cap so the popover never overflows a stub-display Mac — anything
        // past `PopoverList.maxHeight` scrolls inside instead of pushing
        // the popover off the window. The natural content height (3–5
        // models + effort + fast-mode toggle) sits well below the cap, so
        // the cap is a defensive ceiling rather than a routine constraint.
        .frame(width: PopoverList.width)
        .frame(maxHeight: PopoverList.maxHeight)
    }

    /// Effort levels strictly from the active model's
    /// `supportedEffortLevels`. Returns nil to hide the section when
    /// no model is selected or the model declares no effort support.
    ///
    /// `.ultracode` is appended as a final tier for xhigh-capable models —
    /// it isn't a CLI effort level, but the picker offers it as "effort one
    /// notch past xhigh" (selecting it sends `ultracode: true` + xhigh).
    private var activeEffortLevels: [Effort]? {
        guard let value = selectedModelValue,
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
}

/// Two-line popover row: primary (CLI `value`) + secondary
/// (`description`). Layout matches `PopoverRow` (same horizontal inset,
/// same hover/press background) but the height grows for the second
/// line.
private struct ModelPopoverRow: View {
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, PopoverList.horizontalInset)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopoverRowHoverStyle())
    }
}

/// Toggle row inside the popover. Renders an always-enabled
/// `Toggle` with the row's hover/press background so it visually
/// matches the model + effort rows. Clicking the row toggles the
/// switch — the whole row is the hit target, not just the (small,
/// easy-to-miss) switch knob.
private struct FastModeToggleRow: View {
    let enabled: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        Button(action: {
            onToggle(!enabled)
        }) {
            HStack(spacing: 6) {
                Text("Enable fast mode")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { enabled },
                        set: { onToggle($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            .padding(.horizontal, PopoverList.horizontalInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: PopoverList.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
