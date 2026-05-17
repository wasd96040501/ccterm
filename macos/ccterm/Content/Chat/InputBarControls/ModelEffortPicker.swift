import AgentSDK
import SwiftUI

/// Footer-row trigger that opens a stacked Models + Effort popover.
/// Reads the current selection from the handle and writes back via
/// `setModel` / `setEffort`. Models come from
/// `handle.availableModels`, falling back to `ModelStore.cached` so the
/// menu is populated in compose mode before any session has started.
/// Effort levels are filtered per model — only the ones the selected
/// model declares supporting are listed.
struct ModelEffortPicker: View {
    let handle: SessionHandle2
    @State private var isPresented = false

    var body: some View {
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
                onSelectModel: { value in
                    handle.setModel(value)
                    if let effort = handle.effort,
                        let info = visibleModels.first(where: { $0.value == value }),
                        let levels = info.supportedEffortLevels,
                        !levels.isEmpty,
                        !levels.contains(effort.rawValue),
                        let firstSupported = levels.compactMap(Effort.init(rawValue:)).first
                    {
                        // Fall back when the new model doesn't support the
                        // currently-chosen effort — pick the first level it
                        // does support so the picker never holds a stale value.
                        handle.setEffort(firstSupported)
                    }
                },
                onSelectEffort: { effort in
                    handle.setEffort(effort)
                }
            )
        }
    }

    private var visibleModels: [ModelInfo] {
        let live = handle.availableModels
        return live.isEmpty ? ModelStore.cached : live
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
                return info.displayName
            }
            return value
        }
        return String(localized: "Default")
    }
}

private struct ModelEffortPopoverContent: View {
    let models: [ModelInfo]
    let selectedModelValue: String?
    let selectedEffort: Effort?
    let onSelectModel: (String) -> Void
    let onSelectEffort: (Effort) -> Void

    var body: some View {
        VStack(spacing: 0) {
            PopoverSectionHeader(title: String(localized: "Models"))
            if models.isEmpty {
                Text(String(localized: "No models available yet"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, PopoverList.horizontalInset)
                    .padding(.vertical, 6)
            } else {
                ForEach(models, id: \.value) { info in
                    PopoverRow(
                        title: info.displayName,
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
        }
        .padding(PopoverList.outerPadding)
        .frame(width: PopoverList.width)
    }

    /// Levels declared supported by the currently-selected model — or
    /// all SDK levels if the model didn't ship that metadata. Returns
    /// nil when the chosen model explicitly lists zero supported levels
    /// (in which case the Effort section is hidden entirely).
    private var supportedEffortLevels: [Effort]? {
        guard let value = selectedModelValue,
            let info = models.first(where: { $0.value == value })
        else {
            return [.low, .medium, .high, .max]
        }
        guard let raw = info.supportedEffortLevels else {
            return [.low, .medium, .high, .max]
        }
        let mapped = raw.compactMap(Effort.init(rawValue:))
        return mapped.isEmpty ? nil : mapped
    }
}
