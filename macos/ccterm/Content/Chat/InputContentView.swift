import SwiftUI
import AgentSDK

/// Text editing area with left-side buttons (attachment, permission, plugins).
/// Reads handle directly — no intermediate ViewModel.
struct InputContentView: View {
    @Bindable var handle: SessionHandle
    var completionVM: CompletionViewModel

    @Environment(AppViewModel.self) private var appVM

    private let topPadding: CGFloat = 12
    private let contentPadding: CGFloat = 20
    private let buttonSize: CGFloat = 28
    private let buttonSpacing: CGFloat = 4

    @State private var showPluginPicker = false
    @State private var cursorLocation: Int = 0
    @State private var desiredCursorPosition: Int?
    @State private var isFocused: Bool = false
    @Environment(\.self) private var environment
    @AppStorage("sendKeyBehavior") private var sendKeyBehaviorRaw: String = SendKeyBehavior.commandEnter.rawValue

    private var sendKeyBehavior: SendKeyBehavior {
        SendKeyBehavior(rawValue: sendKeyBehaviorRaw) ?? .commandEnter
    }

    var body: some View {
        VStack(spacing: 0) {
            // Text area
            TextInputView(
                text: $handle.draftText,
                isEnabled: !handle.isInputDisabled,
                placeholder: handle.isDirectoryUnset
                    ? sendKeyBehavior.temporarySessionPlaceholder
                    : (handle.status == .responding ? sendKeyBehavior.queuePlaceholder : sendKeyBehavior.sendPlaceholder),
                font: .systemFont(ofSize: 14),
                minLines: 2,
                maxLines: 10,
                onTextChanged: { text, cursor in
                    cursorLocation = cursor
                    completionVM.checkTrigger(
                        text: text,
                        cursorLocation: cursor,
                        hasMarkedText: false,
                        context: CompletionTriggerContext(
                            directory: handle.cwd ?? handle.originPath,
                            additionalDirs: handle.additionalDirectories,
                            pluginDirs: handle.pluginDirectories,
                            slashCommandProvider: handle.slashCommandProvider,
                            onDirectoryPicked: { [weak handle] path in
                                handle?.originPath = path
                            }
                        )
                    )
                },
                onCommandReturn: nil,
                onEscape: nil,
                keyInterceptor: { event in
                    // Shift+Tab → cycle permission mode
                    if event.keyCode == 48, event.modifierFlags.contains(.shift) {
                        handle.cyclePermissionMode()
                        return true
                    }
                    return handleCompletionKeyEvent(event)
                },
                isFocused: $isFocused,
                desiredCursorPosition: $desiredCursorPosition,
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
                if handle.isEffortSupported {
                    effortButton
                        .transition(.opacity)
                }
                pluginButton
                Spacer()
            }
            .padding(.horizontal, contentPadding - buttonSize / 2)
            .padding(.bottom, 6)
            .padding(.top, 8)
            .animation(.smooth(duration: 0.25), value: handle.pluginDirCount)
            .animation(.smooth(duration: 0.25), value: handle.isEffortSupported)
        }
    }

    // MARK: - Completion Key Handling

    private func handleCompletionKeyEvent(_ event: NSEvent) -> Bool {
        guard completionVM.isActive else { return false }

        let keyCode = event.keyCode
        if keyCode == 126 { completionVM.moveSelectionUp(); return true }
        if keyCode == 125 { completionVM.moveSelectionDown(); return true }
        if keyCode == 36 || keyCode == 76 {
            applyCompletionResult(keepSession: false)
            return true
        }
        if keyCode == 49, completionVM.hasInputValidation {
            if tryConfirmCompletionFromInput() { return true }
            return false
        }
        if keyCode == 124, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            applyCompletionResult(keepSession: true)
            return true
        }
        if keyCode == 48 {
            applyCompletionResult(keepSession: false)
            return true
        }
        return false
    }

    private func applyCompletionResult(keepSession: Bool) {
        guard var result = completionVM.confirmSelection(keepSession: keepSession) else { return }
        if keepSession, result.replacement.hasSuffix(" ") {
            result.replacement = String(result.replacement.dropLast())
        }
        let nsText = handle.draftText as NSString
        if result.range.location + result.range.length <= nsText.length {
            let newCursor = result.range.location + result.replacement.count
            handle.draftText = nsText.replacingCharacters(in: result.range, with: result.replacement)
            cursorLocation = newCursor
            desiredCursorPosition = newCursor
        }
    }

    private func tryConfirmCompletionFromInput() -> Bool {
        guard let range = completionVM.tryConfirmFromInput() else { return false }
        let nsText = handle.draftText as NSString
        if range.location + range.length <= nsText.length {
            handle.draftText = nsText.replacingCharacters(in: range, with: "")
            cursorLocation = range.location
            desiredCursorPosition = range.location
        }
        return true
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
                .filter { $0 != .auto || CLICapabilityStore.shared.supportsAutoMode(for: handle.selectedModel) }
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
                    handle.selectPermissionMode(mode)
                }
            }
        ) {
            SlotText(
                text: handle.permissionMode.title,
                ordinal: permissionOrdinal,
                color: handle.permissionMode == .default ? resolvedPrimaryColor : handle.permissionMode.tintColor,
                icon: handle.permissionMode.iconName,
                animated: !handle.animationsDisabled
            )
            .fixedSize()
        }
        .disabled(isTransitioning)
        .hoverTooltip("Shift Tab (⇧⇥)")
    }

    private var permissionOrdinal: Int {
        let filtered = PermissionMode.allCases
            .filter { $0 != .auto || CLICapabilityStore.shared.supportsAutoMode(for: handle.selectedModel) }
        return filtered.firstIndex(of: handle.permissionMode) ?? 0
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
                handle.selectModel(id)
            }
        ) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                SlotText(
                    text: modelDisplayName,
                    ordinal: modelOrdinal,
                    color: resolvedPrimaryColor,
                    animated: !handle.animationsDisabled
                )
                .fixedSize()
            }
            .foregroundStyle(.primary)
        }
        .disabled(isTransitioning)
        .opacity(isTransitioning ? 0.6 : 1.0)
    }

    private var effectiveSelectedModel: String {
        handle.selectedModel ?? "default"
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
        let supportedLevels = CLICapabilityStore.shared.supportedEffortLevels(for: handle.selectedModel)
        return TintedMenuButton(
            items: supportedLevels.map { effort in
                TintedMenuItem(
                    id: effort.rawValue,
                    icon: "",
                    title: effort.title,
                    subtitle: nil,
                    tintColor: .labelColor,
                    isSelected: handle.selectedEffort == effort
                )
            },
            onSelect: { id in
                if let effort = Effort(rawValue: id) {
                    handle.selectEffort(effort)
                }
            }
        ) {
            HStack(spacing: 5) {
                EffortGaugeView(value: handle.selectedEffort.gaugeValue, size: 14)
                SlotText(
                    text: handle.selectedEffort.title,
                    ordinal: effortOrdinal,
                    font: .monospacedSystemFont(ofSize: 12, weight: .medium),
                    color: resolvedPrimaryColor,
                    animated: !handle.animationsDisabled
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
                if handle.pluginDirCount > 0 {
                    Text("\(handle.pluginDirCount)")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(handle.pluginDirCount > 0 ? .primary : .secondary)
        }
        .buttonStyle(HoverCapsuleStyle())
        .disabled(isTransitioning)
        .popover(isPresented: $showPluginPicker) {
            FolderPickerPopover(
                title: String(localized: "Plugins"),
                description: String(localized: "Select plugin directories"),
                mode: .multiSelect,
                readOnly: !handle.isProcessIdle,
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
                handle.pluginDirectories = additional.map(\.path)
                if let dir = handle.originPath {
                    PluginDirStore.saveEnabledDirectories(handle.pluginDirectories, forPath: dir)
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
        Effort.allCases.firstIndex(of: handle.selectedEffort) ?? 0
    }

    private var isTransitioning: Bool {
        handle.status == .starting || handle.status == .interrupting
    }
}
