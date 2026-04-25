import SwiftUI
import AgentSDK

/// 文本编辑区 + 底部按钮(permission / model / effort / plugin)。
/// 直接绑定 `SessionHandle2`,无中间 ViewModel。
struct InputContentView: View {

    @Bindable var handle: SessionHandle2
    @Binding var draftText: String
    @Binding var isInputFocused: Bool
    @Binding var desiredCursorPosition: Int?
    let onCommandReturn: () -> Void
    let onEscape: () -> Void

    private let topPadding: CGFloat = 12
    private let contentPadding: CGFloat = 20
    private let buttonSize: CGFloat = 28
    private let buttonSpacing: CGFloat = 4

    @State private var showPluginPicker = false
    @Environment(\.self) private var environment
    @AppStorage("sendKeyBehavior") private var sendKeyBehaviorRaw: String = SendKeyBehavior.commandEnter.rawValue

    private var sendKeyBehavior: SendKeyBehavior {
        SendKeyBehavior(rawValue: sendKeyBehaviorRaw) ?? .commandEnter
    }

    private var status: SessionHandle2.Status { handle.status }
    private var isInputDisabled: Bool { status == .starting || status == .interrupting }
    private var isProcessIdle: Bool { status == .notStarted || status == .stopped }
    private var isTransitioning: Bool { status == .starting || status == .interrupting }
    private var isDirectoryUnset: Bool {
        status == .notStarted && handle.originPath == nil && handle.cwd == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            TextInputView(
                text: $draftText,
                isEnabled: !isInputDisabled,
                placeholder: placeholder,
                font: .systemFont(ofSize: 14),
                minLines: 2,
                maxLines: 10,
                onCommandReturn: onCommandReturn,
                onEscape: onEscape,
                isFocused: $isInputFocused,
                desiredCursorPosition: $desiredCursorPosition,
                sendKeyBehavior: sendKeyBehavior
            )
            .padding(.top, topPadding)
            .padding(.horizontal, contentPadding - 7)

            HStack(spacing: buttonSpacing) {
                permissionButton
                if !CLICapabilityStore.shared.availableModels.isEmpty {
                    modelButton
                }
                if isEffortSupported {
                    effortButton
                        .transition(.opacity)
                }
                pluginButton
                Spacer()
            }
            .padding(.horizontal, contentPadding - buttonSize / 2)
            .padding(.bottom, 6)
            .padding(.top, 8)
            .animation(.smooth(duration: 0.25), value: handle.pluginDirectories.count)
            .animation(.smooth(duration: 0.25), value: isEffortSupported)
        }
    }

    private var placeholder: String {
        if isDirectoryUnset {
            return sendKeyBehavior.temporarySessionPlaceholder
        }
        if status == .responding {
            return sendKeyBehavior.queuePlaceholder
        }
        return sendKeyBehavior.sendPlaceholder
    }

    // MARK: - Buttons

    private var permissionButton: some View {
        TintedMenuButton(
            items: PermissionMode.allCases
                .filter { $0 != .auto || CLICapabilityStore.shared.supportsAutoMode(for: handle.model) }
                .map { mode in
                    TintedMenuItem(
                        id: mode.rawValue,
                        icon: mode.iconName,
                        title: mode.title,
                        subtitle: mode.subtitle,
                        tintColor: mode.tintColor,
                        isSelected: handle.permissionMode == mode
                    )
                },
            onSelect: { id in
                if let mode = PermissionMode(rawValue: id) {
                    handle.setPermissionMode(mode)
                }
            }
        ) {
            SlotText(
                text: handle.permissionMode.title,
                ordinal: permissionOrdinal,
                color: handle.permissionMode == .default ? resolvedPrimaryColor : handle.permissionMode.tintColor,
                icon: handle.permissionMode.iconName,
                animated: true
            )
            .fixedSize()
        }
        .disabled(isTransitioning)
        .hoverTooltip("Shift Tab (⇧⇥)")
    }

    private var permissionOrdinal: Int {
        let filtered = PermissionMode.allCases
            .filter { $0 != .auto || CLICapabilityStore.shared.supportsAutoMode(for: handle.model) }
        return filtered.firstIndex(of: handle.permissionMode) ?? 0
    }

    private var modelButton: some View {
        let models = CLICapabilityStore.shared.availableModels
        return TintedMenuButton(
            items: models.map { model in
                TintedMenuItem(
                    id: model.value,
                    icon: "sparkles",
                    title: model.displayName,
                    subtitle: model.description,
                    tintColor: .labelColor,
                    isSelected: effectiveSelectedModel == model.value
                )
            },
            onSelect: { id in
                handle.setModel(id)
            }
        ) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                SlotText(
                    text: modelDisplayName,
                    ordinal: modelOrdinal,
                    color: resolvedPrimaryColor,
                    animated: true
                )
                .fixedSize()
            }
            .foregroundStyle(.primary)
        }
        .disabled(isTransitioning)
        .opacity(isTransitioning ? 0.6 : 1.0)
    }

    private var effectiveSelectedModel: String {
        handle.model ?? "default"
    }

    private var modelOrdinal: Int {
        let models = CLICapabilityStore.shared.availableModels
        return models.firstIndex(where: { $0.value == effectiveSelectedModel }) ?? 0
    }

    private var modelDisplayName: String {
        let value = effectiveSelectedModel
        return CLICapabilityStore.shared.availableModels
            .first { $0.value == value }?.displayName
            ?? (value == "default" ? "Default" : value)
    }

    private var isEffortSupported: Bool {
        !CLICapabilityStore.shared.supportedEffortLevels(for: handle.model).isEmpty
    }

    private var currentEffort: Effort { handle.effort ?? .medium }

    private var effortButton: some View {
        let supportedLevels = CLICapabilityStore.shared.supportedEffortLevels(for: handle.model)
        return TintedMenuButton(
            items: supportedLevels.map { effort in
                TintedMenuItem(
                    id: effort.rawValue,
                    icon: "",
                    title: effort.title,
                    subtitle: nil,
                    tintColor: .labelColor,
                    isSelected: currentEffort == effort
                )
            },
            onSelect: { id in
                if let effort = Effort(rawValue: id) {
                    handle.setEffort(effort)
                }
            }
        ) {
            HStack(spacing: 5) {
                EffortGaugeView(value: currentEffort.gaugeValue, size: 14)
                SlotText(
                    text: currentEffort.title,
                    ordinal: effortOrdinal,
                    font: .monospacedSystemFont(ofSize: 12, weight: .medium),
                    color: resolvedPrimaryColor,
                    animated: true
                )
                .fixedSize()
            }
            .foregroundStyle(.primary)
        }
        .disabled(isTransitioning)
        .opacity(isTransitioning ? 0.6 : 1.0)
    }

    private var pluginButton: some View {
        Button { showPluginPicker = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 12, weight: .medium))
                if !handle.pluginDirectories.isEmpty {
                    Text("\(handle.pluginDirectories.count)")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(handle.pluginDirectories.isEmpty ? .secondary : .primary)
        }
        .buttonStyle(HoverCapsuleStyle())
        .disabled(isTransitioning)
        .popover(isPresented: $showPluginPicker) {
            FolderPickerPopover(
                title: String(localized: "Plugins"),
                description: String(localized: "Select plugin directories"),
                mode: .multiSelect,
                readOnly: !handle.canSetPluginDirectories,
                initialAdditional: Set(handle.pluginDirectories.map { URL(fileURLWithPath: $0) }),
                loadFolders: { PluginDirStore.directories.map { URL(fileURLWithPath: $0) } },
                saveFolders: { urls in
                    let paths = Set(urls.map(\.path))
                    let existing = Set(PluginDirStore.directories)
                    for p in paths.subtracting(existing) { PluginDirStore.addDirectory(p) }
                    for p in existing.subtracting(paths) { PluginDirStore.removeDirectory(p) }
                }
            ) { _, additional in
                showPluginPicker = false
                let dirs = additional.map(\.path)
                handle.setPluginDirectories(dirs)
                if let dir = handle.originPath ?? handle.cwd {
                    PluginDirStore.saveEnabledDirectories(dirs, forPath: dir)
                }
            }
        }
    }

    // MARK: - Helpers

    private var resolvedPrimaryColor: NSColor {
        let c = Color.primary.resolve(in: environment)
        return NSColor(red: CGFloat(c.red), green: CGFloat(c.green),
                       blue: CGFloat(c.blue), alpha: CGFloat(c.opacity))
    }

    private var effortOrdinal: Int {
        Effort.allCases.firstIndex(of: currentEffort) ?? 0
    }
}
