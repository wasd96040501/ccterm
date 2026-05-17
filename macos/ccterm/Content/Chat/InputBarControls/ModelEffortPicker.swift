import AgentSDK
import SwiftUI

/// Footer-row trigger that opens a stacked Models + Effort + Fast mode
/// popover. Reads the current selection from the handle and writes back
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
    let handle: SessionHandle2
    @State private var isPresented = false
    @State private var store = ModelStore.shared

    var body: some View {
        HStack(spacing: 6) {
            BarChromeButton(label: {
                triggerLabel
            }) {
                isPresented.toggle()
            }
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                ModelEffortPopoverContent(
                    models: visibleModels,
                    selectedModelValue: handle.model,
                    selectedEffort: effectiveEffort,
                    fastModeEnabled: handle.fastModeEnabled,
                    onSelectModel: { value in
                        applyModelSelection(value)
                        isPresented = false
                    },
                    onSelectEffort: { effort in
                        handle.setEffort(effort)
                        if let value = handle.model {
                            EffortDefaultStore.shared.remember(effort, for: value)
                        }
                        isPresented = false
                    },
                    onToggleFastMode: { enabled in
                        handle.setFastMode(enabled)
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
    }

    /// Per-session catalog wins; fall through to the cross-launch
    /// `ModelStore` cache only when the session hasn't replied yet.
    private var visibleModels: [ModelInfo] {
        let live = handle.availableModels
        return live.isEmpty ? store.models : live
    }

    private var selectedModelInfo: ModelInfo? {
        guard let value = handle.model else { return nil }
        return visibleModels.first(where: { $0.value == value })
    }

    /// Effort to show as "selected" in trigger + popover. Real
    /// `handle.effort` wins; otherwise the per-model default from
    /// `EffortDefaultStore`. nil only when no model is selected or the
    /// model declares no effort support.
    private var effectiveEffort: Effort? {
        if let effort = handle.effort { return effort }
        guard let info = selectedModelInfo else { return nil }
        return EffortDefaultStore.shared.effort(for: info)
    }

    /// Switching model: write the new value, then resolve the model's
    /// remembered/default effort and push it through `setEffort` so
    /// the CLI receives an effort consistent with what the UI shows.
    private func applyModelSelection(_ value: String) {
        handle.setModel(value)
        guard let info = visibleModels.first(where: { $0.value == value }),
            let resolved = EffortDefaultStore.shared.effort(for: info)
        else { return }
        handle.setEffort(resolved)
    }

    @ViewBuilder
    private var triggerLabel: some View {
        HStack(spacing: 4) {
            Text(handle.model ?? "Model")
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
        .frame(width: PopoverList.width)
    }

    /// Effort levels strictly from the active model's
    /// `supportedEffortLevels`. Returns nil to hide the section when
    /// no model is selected or the model declares no effort support.
    private var activeEffortLevels: [Effort]? {
        guard let value = selectedModelValue,
            let info = models.first(where: { $0.value == value }),
            info.supportsEffort == true,
            let raw = info.supportedEffortLevels
        else { return nil }
        let mapped = raw.compactMap(Effort.init(rawValue:))
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
