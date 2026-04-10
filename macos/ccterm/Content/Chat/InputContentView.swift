import SwiftUI
import AgentSDK

/// Text editing area with left-side buttons (attachment, permission, plugins).
struct InputContentView: View {
    @Bindable var viewModel: InputBarViewModel

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

    var body: some View {
        VStack(spacing: 0) {
            // Text area
            TextInputView(
                text: $viewModel.inputVM.text,
                isEnabled: !viewModel.isInputDisabled,
                placeholder: viewModel.isDirectoryUnset
                    ? sendKeyBehavior.temporarySessionPlaceholder
                    : (viewModel.barState == .responding ? sendKeyBehavior.queuePlaceholder : sendKeyBehavior.sendPlaceholder),
                font: .systemFont(ofSize: 14),
                minLines: 2,
                maxLines: 10,
                onTextChanged: { text, cursor in
                    viewModel.inputVM.cursorLocation = cursor
                    viewModel.inputVM.checkCompletion(
                        text: text,
                        cursor: cursor,
                        hasMarkedText: false,
                        context: CompletionTriggerContext(
                            directory: viewModel.cwd,
                            additionalDirs: viewModel.additionalDirectories,
                            pluginDirs: viewModel.pluginDirectories,
                            slashCommandProvider: viewModel.inputVM.slashCommandProvider,
                            onDirectoryPicked: { [weak viewModel] path in
                                viewModel?.originPath = path
                            }
                        )
                    )
                },
                onCommandReturn: {
                    viewModel.handleCommandReturn()
                },
                onEscape: {
                    viewModel.handleEscape()
                },
                keyInterceptor: { event in
                    // Shift+Tab → cycle permission mode
                    if event.keyCode == 48, event.modifierFlags.contains(.shift) {
                        viewModel.cyclePermissionMode()
                        return true
                    }
                    return viewModel.inputVM.handleKeyEvent(event)
                },
                isFocused: $viewModel.inputVM.isFocused,
                desiredCursorPosition: $viewModel.inputVM.desiredCursorPosition,
                sendKeyBehavior: sendKeyBehavior
            )
            .padding(.top, topPadding)
            .padding(.horizontal, contentPadding - 7)

            // Bottom buttons row
            HStack(spacing: buttonSpacing) {
                attachButton
                permissionButton
                if !CLICapabilityStore.shared.availableModels.isEmpty {
                    modelButton
                }
                if viewModel.isEffortSupported {
                    effortButton
                        .transition(.opacity)
                }
                pluginButton
                Spacer()
            }
            .padding(.horizontal, contentPadding - buttonSize / 2)
            .padding(.bottom, 6)
            .padding(.top, 8)
            .animation(.smooth(duration: 0.25), value: viewModel.pluginDirCount)
            .animation(.smooth(duration: 0.25), value: viewModel.isEffortSupported)
        }
    }

    // MARK: - Buttons

    private var attachButton: some View {
        Button {
            // Attachment not yet implemented
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: buttonSize, height: buttonSize)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .disabled(isTransitioning)
    }

    private var permissionButton: some View {
        TintedMenuButton(
            items: PermissionMode.allCases
                .filter { $0 != .auto || CLICapabilityStore.shared.supportsAutoMode(for: viewModel.selectedModel) }
                .map { mode in
                    TintedMenuItem(
                        id: mode.rawValue,
                        icon: mode.iconName,
                        title: mode.title,
                        subtitle: mode.subtitle,
                        tintColor: mode.tintColor,
                        isSelected: viewModel.permissionMode == mode
                    )
                },
            onSelect: { id in
                if let mode = PermissionMode(rawValue: id) {
                    viewModel.selectPermissionMode(mode)
                }
            }
        ) {
            SlotText(
                text: viewModel.permissionMode.title,
                ordinal: permissionOrdinal,
                color: viewModel.permissionMode == .default ? resolvedPrimaryColor : viewModel.permissionMode.tintColor,
                icon: viewModel.permissionMode.iconName,
                animated: !viewModel.animationsDisabled
            )
            .fixedSize()
        }
        .disabled(isTransitioning)
        .hoverTooltip("Shift Tab (⇧⇥)")
    }

    private var permissionOrdinal: Int {
        let filtered = PermissionMode.allCases
            .filter { $0 != .auto || CLICapabilityStore.shared.supportsAutoMode(for: viewModel.selectedModel) }
        return filtered.firstIndex(of: viewModel.permissionMode) ?? 0
    }

    private var modelButton: some View {
        let models = CLICapabilityStore.shared.availableModels
        return TintedMenuButton(
            items: {
                if models.isEmpty {
                    return [TintedMenuItem(
                        id: "default",
                        icon: "sparkles",
                        title: "Default",
                        subtitle: String(localized: "Available after session starts"),
                        tintColor: .labelColor,
                        isSelected: true
                    )]
                }
                return models.map { model in
                    TintedMenuItem(
                        id: model.value,
                        icon: "sparkles",
                        title: model.displayName,
                        subtitle: model.description,
                        tintColor: .labelColor,
                        isSelected: effectiveSelectedModel == model.value
                    )
                }
            }(),
            onSelect: { id in
                viewModel.selectModel(id)
            }
        ) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                SlotText(
                    text: modelDisplayName,
                    ordinal: modelOrdinal,
                    color: resolvedPrimaryColor,
                    animated: !viewModel.animationsDisabled
                )
                .fixedSize()
            }
            .foregroundStyle(.primary)
        }
        .disabled(isTransitioning)
        .opacity(isTransitioning ? 0.6 : 1.0)
    }

    private var effectiveSelectedModel: String {
        viewModel.selectedModel ?? "default"
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

    private var effortButton: some View {
        let supportedLevels = CLICapabilityStore.shared.supportedEffortLevels(for: viewModel.selectedModel)
        return TintedMenuButton(
            items: supportedLevels.map { effort in
                TintedMenuItem(
                    id: effort.rawValue,
                    icon: "",
                    title: effort.title,
                    subtitle: nil,
                    tintColor: .labelColor,
                    isSelected: viewModel.selectedEffort == effort
                )
            },
            onSelect: { id in
                if let effort = Effort(rawValue: id) {
                    viewModel.selectEffort(effort)
                }
            }
        ) {
            HStack(spacing: 5) {
                EffortGaugeView(value: viewModel.selectedEffort.gaugeValue, size: 14)
                SlotText(
                    text: viewModel.selectedEffort.title,
                    ordinal: effortOrdinal,
                    font: .monospacedSystemFont(ofSize: 12, weight: .medium),
                    color: resolvedPrimaryColor,
                    animated: !viewModel.animationsDisabled
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
                if viewModel.pluginDirCount > 0 {
                    Text("\(viewModel.pluginDirCount)")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(viewModel.pluginDirCount > 0 ? .primary : .secondary)
        }
        .buttonStyle(HoverCapsuleStyle())
        .disabled(isTransitioning)
        .popover(isPresented: $showPluginPicker) {
            FolderPickerPopover(
                title: String(localized: "Plugins"),
                description: String(localized: "Select plugin directories"),
                mode: .multiSelect,
                readOnly: !viewModel.isProcessIdle,
                initialAdditional: Set(viewModel.pluginDirectories.map { URL(fileURLWithPath: $0) }),
                loadFolders: { PluginDirStore.directories.map { URL(fileURLWithPath: $0) } },
                saveFolders: { urls in
                    let paths = Set(urls.map(\.path))
                    let existing = Set(PluginDirStore.directories)
                    for p in paths.subtracting(existing) { PluginDirStore.addDirectory(p) }
                    for p in existing.subtracting(paths) { PluginDirStore.removeDirectory(p) }
                }
            ) { _, additional in
                showPluginPicker = false
                viewModel.pluginDirectories = additional.map(\.path)
                if let dir = viewModel.originPath {
                    PluginDirStore.saveEnabledDirectories(viewModel.pluginDirectories, forPath: dir)
                }
            }
        }
    }

    // MARK: - State

    private var resolvedPrimaryColor: NSColor {
        let c = Color.primary.resolve(in: environment)
        return NSColor(red: CGFloat(c.red), green: CGFloat(c.green),
                       blue: CGFloat(c.blue), alpha: CGFloat(c.opacity))
    }

    private var effortOrdinal: Int {
        Effort.allCases.firstIndex(of: viewModel.selectedEffort) ?? 0
    }

    /// 过渡态（starting/interrupting），所有按钮禁用
    private var isTransitioning: Bool {
        viewModel.barState == .starting || viewModel.barState == .interrupting
    }
}
