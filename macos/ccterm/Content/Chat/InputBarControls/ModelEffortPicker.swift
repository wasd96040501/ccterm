import AgentSDK
import SwiftUI

/// Footer-row trigger that opens a stacked Models + Effort + Fast mode
/// popover. Reads the current selection from the handle and writes back
/// via `setModel` / `setEffort` / `setFastMode`. The model catalog
/// streams from `ModelStore.shared`, kicked off at app launch — the
/// trigger renders a small `ProgressView` next to its label while the
/// first fetch is in flight.
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
                // Model / effort selections close the popover on tap.
                // This is both the standard menu-row affordance AND
                // the cheapest fix for popover-anchor drift: the
                // trigger's intrinsic width is allowed to update
                // immediately (no "freeze" hack), but it only does so
                // *after* the popover has dismissed — so the anchor
                // never moves while the menu is on screen. Fast-mode
                // is a switch, not a menu row, so it stays open.
                ModelEffortPopoverContent(
                    models: visibleModels,
                    selectedModelValue: handle.model,
                    selectedEffort: handle.effort,
                    fastModeEnabled: handle.fastModeEnabled,
                    fastModeSupported: selectedModelInfo?.supportsFastMode ?? false,
                    onSelectModel: { value in
                        handle.setModel(value)
                        reconcileEffortIfNeeded(forModelValue: value)
                        isPresented = false
                    },
                    onSelectEffort: { effort in
                        handle.setEffort(effort)
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

    private var visibleModels: [ModelInfo] {
        let live = handle.availableModels
        return live.isEmpty ? store.models : live
    }

    /// Resolve the model the picker should treat as "current" for
    /// feature-flag lookups (fast mode, effort levels). When the user
    /// hasn't explicitly picked one (`handle.model == nil`) we fall
    /// back to the first entry in `visibleModels`, which the CLI lists
    /// as the recommended default — otherwise the fast-mode toggle
    /// reads as permanently disabled even though the default model
    /// supports it.
    private var selectedModelInfo: ModelInfo? {
        Self.resolveCurrentModel(value: handle.model, in: visibleModels)
    }

    /// Pure resolver split out of the View body so it can be unit-
    /// tested without standing up a SwiftUI hierarchy.
    static func resolveCurrentModel(value: String?, in models: [ModelInfo]) -> ModelInfo? {
        if let value, let exact = models.first(where: { $0.value == value }) {
            return exact
        }
        return models.first
    }

    @ViewBuilder
    private var triggerLabel: some View {
        HStack(spacing: 4) {
            Text(modelDisplay)
                .foregroundStyle(.primary)
            if let effort = handle.effort {
                Text("·")
                    .foregroundStyle(.secondary)
                Text(effort.title)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modelDisplay: String {
        if let value = handle.model {
            if let info = visibleModels.first(where: { $0.value == value }) {
                return info.conciseDisplayName
            }
            return value
        }
        return "Default"
    }

    /// When the user picks a new model, drop the current effort if it
    /// isn't in the new model's `supportedEffortLevels` and fall back to
    /// the first level the new model does support. Keeps the popover
    /// from ever showing a stale checked level.
    private func reconcileEffortIfNeeded(forModelValue value: String) {
        guard let effort = handle.effort,
            let info = visibleModels.first(where: { $0.value == value }),
            let levels = info.supportedEffortLevels,
            !levels.isEmpty,
            !levels.contains(effort.rawValue),
            let firstSupported = levels.compactMap(Effort.init(rawValue:)).first
        else { return }
        handle.setEffort(firstSupported)
    }
}

private struct ModelEffortPopoverContent: View {
    let models: [ModelInfo]
    let selectedModelValue: String?
    let selectedEffort: Effort?
    let fastModeEnabled: Bool
    let fastModeSupported: Bool
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
                    PopoverRow(
                        title: info.conciseDisplayName,
                        isSelected: info.value == selectedModelValue,
                        onSelect: { onSelectModel(info.value) }
                    )
                }
            }

            if let levels = supportedEffortLevels, !levels.isEmpty {
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
                supported: fastModeSupported,
                onToggle: onToggleFastMode
            )
        }
        .padding(PopoverList.outerPadding)
        .frame(width: PopoverList.width)
    }

    /// Levels declared supported by the currently-selected model — or
    /// the full SDK set if the model didn't ship metadata. Returns nil
    /// when the model explicitly lists zero (the section is then hidden).
    private var supportedEffortLevels: [Effort]? {
        guard let value = selectedModelValue,
            let info = models.first(where: { $0.value == value })
        else {
            return [.low, .medium, .high, .xhigh, .max]
        }
        guard let raw = info.supportedEffortLevels else {
            return [.low, .medium, .high, .xhigh, .max]
        }
        let mapped = raw.compactMap(Effort.init(rawValue:))
        return mapped.isEmpty ? nil : mapped
    }
}

/// Toggle row inside the popover. Renders a `Toggle` with the row's
/// hover/press background so it visually matches the model + effort
/// rows. Disabled (and grayed) when the selected model doesn't declare
/// `supportsFastMode == true`, matching Claude.app's "Enable fast mode"
/// row that grays out on incompatible models.
private struct FastModeToggleRow: View {
    let enabled: Bool
    let supported: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        // Whole-row hit target — clicking the label flips the toggle,
        // not just clicking the (small, easy-to-miss) switch knob. The
        // earlier version only registered taps inside the .switch's
        // hit shape, so the row felt "unclickable" when aiming at the
        // label.
        Button(action: {
            guard supported else { return }
            onToggle(!enabled)
        }) {
            HStack(spacing: 6) {
                Text("Enable fast mode")
                    .font(.system(size: 13))
                    .foregroundStyle(supported ? .primary : .secondary)
                Spacer(minLength: 0)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { enabled && supported },
                        set: { newValue in
                            guard supported else { return }
                            onToggle(newValue)
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!supported)
                // The toggle's hit testing is preserved so clicks on
                // the knob still work; the Button wrapper just adds a
                // larger label-area target.
                .allowsHitTesting(supported)
            }
            .padding(.horizontal, PopoverList.horizontalInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: PopoverList.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!supported)
    }
}
