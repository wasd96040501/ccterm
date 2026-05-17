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
                ModelEffortPopoverContent(
                    models: visibleModels,
                    selectedModelValue: handle.model,
                    selectedEffort: handle.effort,
                    fastModeEnabled: handle.fastModeEnabled,
                    fastModeSupported: selectedModelInfo?.supportsFastMode ?? false,
                    onSelectModel: { value in
                        handle.setModel(value)
                        reconcileEffortIfNeeded(forModelValue: value)
                    },
                    onSelectEffort: { effort in
                        handle.setEffort(effort)
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
                    .accessibilityLabel(String(localized: "Loading models"))
            }
        }
    }

    private var visibleModels: [ModelInfo] {
        let live = handle.availableModels
        return live.isEmpty ? store.models : live
    }

    private var selectedModelInfo: ModelInfo? {
        guard let value = handle.model else { return nil }
        return visibleModels.first { $0.value == value }
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
        return String(localized: "Default")
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
            PopoverSectionHeader(title: String(localized: "Models"))
            if models.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).scaleEffect(0.85)
                    Text(String(localized: "Loading models…"))
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
                PopoverSectionHeader(title: String(localized: "Effort"))
                ForEach(levels, id: \.rawValue) { effort in
                    PopoverRow(
                        title: effort.title,
                        isSelected: effort == selectedEffort,
                        onSelect: { onSelectEffort(effort) }
                    )
                }
            }

            Divider().padding(.vertical, 4)
            PopoverSectionHeader(title: String(localized: "Fast mode"))
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
        HStack(spacing: 6) {
            Text(String(localized: "Enable fast mode"))
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
        }
        .padding(.horizontal, PopoverList.horizontalInset)
        .frame(height: PopoverList.rowHeight)
    }
}
