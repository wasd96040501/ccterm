import SwiftUI
import AgentSDK

/// Text editing area with left-side buttons (attachment, permission, plugins).
struct SwiftUIInputContentView: View {
    @Bindable var state: ChatSessionViewModel
    let actions: ChatInputBarActions
    var isCommentMode: Bool = false

    private let topPadding: CGFloat = 12
    private let contentPadding: CGFloat = 20
    private let buttonSize: CGFloat = 28
    private let buttonSpacing: CGFloat = 4
    private let quoteMaxHeight: CGFloat = 130

    @State private var quoteContentHeight: CGFloat = 0
    @State private var showPluginPicker = false
    @Environment(\.self) private var environment
    @AppStorage("sendKeyBehavior") private var sendKeyBehaviorRaw: String = SendKeyBehavior.commandEnter.rawValue

    private var sendKeyBehavior: SendKeyBehavior {
        SendKeyBehavior(rawValue: sendKeyBehaviorRaw) ?? .commandEnter
    }

    var body: some View {
        VStack(spacing: 0) {
            // Selection quote bars (comment mode, supports multiple quotes)
            if isCommentMode, !state.pendingCommentSelections.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    quoteList
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            guard height != quoteContentHeight else { return }
                            DispatchQueue.main.async {
                                withAnimation(.smooth(duration: 0.35)) {
                                    quoteContentHeight = height
                                }
                            }
                        }
                }
                .frame(height: min(quoteContentHeight, quoteMaxHeight))
                Divider()
            }

            // Text area
            SwiftUITextInputView(
                text: $state.inputText,
                isEnabled: !isDisabled,
                placeholder: isCommentMode
                    ? sendKeyBehavior.commentPlaceholder
                    : (state.isDirectoryUnset ? sendKeyBehavior.temporarySessionPlaceholder : (state.barState == .responding ? sendKeyBehavior.queuePlaceholder : sendKeyBehavior.sendPlaceholder)),

                font: .systemFont(ofSize: 14),
                minLines: 2,
                maxLines: 10,
                onTextChanged: { text, cursor in
                    state.cursorLocation = cursor
                    state.completion.checkTrigger(
                        text: text,
                        cursorLocation: cursor,
                        hasMarkedText: false,
                        context: CompletionTriggerContext(
                            directory: state.selectedDirectory,
                            additionalDirs: state.additionalDirectories,
                            pluginDirs: state.pluginDirectories,
                            slashCommandProvider: state.slashCommandProvider,
                            onDirectoryPicked: { [state] path in
                                state.selectedDirectory = path
                                state.branchMonitor.monitor(directory: path)
                            }
                        )
                    )
                },
                onCommandReturn: {
                    handleCommandReturn()
                },
                onEscape: {
                    handleEscape()
                },
                keyInterceptor: { event in
                    handleKeyEvent(event)
                },
                isFocused: $state.isFocused,
                desiredCursorPosition: $state.desiredCursorPosition,
                sendKeyBehavior: sendKeyBehavior
            )
            .padding(.top, topPadding)
            .padding(.horizontal, contentPadding - 7)

            // Bottom buttons row (hidden in comment mode)
            if !isCommentMode {
                HStack(spacing: buttonSpacing) {
                    attachButton
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
                .animation(.smooth(duration: 0.25), value: state.pluginDirCount)
                .animation(.smooth(duration: 0.25), value: isEffortSupported)
            } else {
                Spacer().frame(height: 42)
            }
        }
    }

    // MARK: - Quote List

    private var quoteList: some View {
        VStack(spacing: 0) {
            ForEach(Array(state.pendingCommentSelections.enumerated()), id: \.element.id) { index, selection in
                HStack(spacing: 0) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .padding(.leading, 13)
                    Text(selection.selectedText.trimmedForQuote)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .padding(.leading, 6)
                        .padding(.vertical, 4)
                    Spacer(minLength: 8)
                    Button {
                        state.pendingCommentSelections.removeAll { $0.id == selection.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 16, height: 16)
                    .padding(.trailing, 8)
                }
                .background(index % 2 == 1 ? Color(nsColor: .controlAlternatingRowBackgroundColors[1]) : Color.clear)
            }
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
                .filter { $0 != .auto || CLICapabilityStore.shared.supportsAutoMode(for: state.selectedModel) }
                .map { mode in
                    TintedMenuItem(
                        id: mode.rawValue,
                        icon: mode.iconName,
                        title: mode.title,
                        subtitle: mode.subtitle,
                        tintColor: mode.tintColor,
                        isSelected: state.permissionMode == mode
                    )
                },
            onSelect: { id in
                if let mode = PermissionMode(rawValue: id) {
                    state.selectPermissionMode(mode)
                }
            }
        ) {
            SlotText(
                text: state.permissionMode.title,
                ordinal: permissionOrdinal,
                color: state.permissionMode == .default ? resolvedPrimaryColor : state.permissionMode.tintColor,
                icon: state.permissionMode.iconName,
                animated: !state.animationsDisabled
            )
            .fixedSize()
        }
        .disabled(isTransitioning)
        .hoverTooltip("Shift Tab (⇧⇥)")
    }

    private var permissionOrdinal: Int {
        let filtered = PermissionMode.allCases
            .filter { $0 != .auto || CLICapabilityStore.shared.supportsAutoMode(for: state.selectedModel) }
        return filtered.firstIndex(of: state.permissionMode) ?? 0
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
                state.selectModel(id)
                reconcileCapabilitiesForModel(id)
            }
        ) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                SlotText(
                    text: modelDisplayName,
                    ordinal: modelOrdinal,
                    color: resolvedPrimaryColor,
                    animated: !state.animationsDisabled
                )
                .fixedSize()
            }
            .foregroundStyle(.primary)
        }
        .disabled(isTransitioning)
        .opacity(isTransitioning ? 0.6 : 1.0)
    }

    /// nil 归一化为 "default"
    private var effectiveSelectedModel: String {
        state.selectedModel ?? "default"
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
        let supportedLevels = CLICapabilityStore.shared.supportedEffortLevels(for: state.selectedModel)
        return TintedMenuButton(
            items: supportedLevels.map { effort in
                TintedMenuItem(
                    id: effort.rawValue,
                    icon: "",
                    title: effort.title,
                    subtitle: nil,
                    tintColor: .labelColor,
                    isSelected: state.selectedEffort == effort
                )
            },
            onSelect: { id in
                if let effort = Effort(rawValue: id) {
                    state.selectEffort(effort)
                }
            }
        ) {
            HStack(spacing: 5) {
                EffortGaugeView(value: state.selectedEffort.gaugeValue, size: 14)
                SlotText(
                    text: state.selectedEffort.title,
                    ordinal: effortOrdinal,
                    font: .monospacedSystemFont(ofSize: 12, weight: .medium),
                    color: resolvedPrimaryColor,
                    animated: !state.animationsDisabled
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
                if state.pluginDirCount > 0 {
                    Text("\(state.pluginDirCount)")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(state.pluginDirCount > 0 ? .primary : .secondary)
        }
        .buttonStyle(HoverCapsuleStyle())
        .disabled(isTransitioning)
        .popover(isPresented: $showPluginPicker) {
            FolderPickerPopover(
                title: String(localized: "Plugins"),
                description: String(localized: "Select plugin directories"),
                mode: .multiSelect,
                readOnly: !state.isProcessIdle,
                initialAdditional: Set(state.pluginDirectories.map { URL(fileURLWithPath: $0) }),
                loadFolders: { PluginDirStore.directories.map { URL(fileURLWithPath: $0) } },
                saveFolders: { urls in
                    let paths = Set(urls.map(\.path))
                    let existing = Set(PluginDirStore.directories)
                    for p in paths.subtracting(existing) { PluginDirStore.addDirectory(p) }
                    for p in existing.subtracting(paths) { PluginDirStore.removeDirectory(p) }
                }
            ) { _, additional in
                showPluginPicker = false
                state.pluginDirectories = additional.map(\.path)
                if let dir = state.selectedDirectory {
                    PluginDirStore.saveEnabledDirectories(state.pluginDirectories, forPath: dir)
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

    /// 文本输入框禁用
    private var isDisabled: Bool {
        state.barState == .starting || state.barState == .interrupting
    }

    private var effortOrdinal: Int {
        Effort.allCases.firstIndex(of: state.selectedEffort) ?? 0
    }

    private var isEffortSupported: Bool {
        !CLICapabilityStore.shared.supportedEffortLevels(for: state.selectedModel).isEmpty
    }

    /// 过渡态（starting/interrupting），所有按钮禁用
    private var isTransitioning: Bool {
        state.barState == .starting || state.barState == .interrupting
    }

    /// 切换模型后，将不支持的 effort / permission mode 兜底到默认值。
    private func reconcileCapabilitiesForModel(_ modelValue: String?) {
        let store = CLICapabilityStore.shared
        let supportedLevels = store.supportedEffortLevels(for: modelValue)
        if !supportedLevels.isEmpty && !supportedLevels.contains(state.selectedEffort) {
            state.selectEffort(.medium)
        }
        if state.permissionMode == .auto && !store.supportsAutoMode(for: modelValue) {
            state.selectPermissionMode(.default)
        }
    }

    // MARK: - Key Handling

    private func handleCommandReturn() {
        if state.isViewingPlan {
            state.sendComment()
        } else if state.isInPermissionMode {
            if let card = state.currentPermissionCard, card.cardType.canConfirm {
                card.cardType.confirm()
            }
        } else if state.barState == .responding {
            let text = state.trimmedText
            if !text.isEmpty {
                state.queueMessage(text)
                state.clearInput()
            }
        } else if state.canSend {
            state.deleteDraft()
            actions.onSend(state.trimmedText)
        }
    }

    private func handleEscape() {
        if state.completion.isActive {
            state.completion.dismiss()
        } else if state.barState == .responding {
            state.interrupt()
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Shift+Tab → cycle permission mode
        if event.keyCode == 48, event.modifierFlags.contains(.shift) {
            state.cyclePermissionMode()
            return true
        }

        guard state.completion.isActive else { return false }

        let keyCode = event.keyCode
        // Up arrow
        if keyCode == 126 { state.completion.moveSelectionUp(); return true }
        // Down arrow
        if keyCode == 125 { state.completion.moveSelectionDown(); return true }
        // Return / Enter
        if keyCode == 36 || keyCode == 76 {
            state.applyCompletionResult(keepSession: false)
            return true
        }
        // Space — try input validation if session supports it (e.g. directory pick)
        if keyCode == 49, state.completion.hasInputValidation {
            if state.tryConfirmCompletionFromInput() { return true }
            return false  // let space insert normally; updateQuery will suspend
        }
        // Right arrow — drill down, keep session open for deeper navigation
        // With modifier keys (⌘/⌃/⌥), fall through to normal text editing
        if keyCode == 124, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            state.applyCompletionResult(keepSession: true)
            return true
        }
        // Tab — confirm, same as Enter
        if keyCode == 48 {
            state.applyCompletionResult(keepSession: false)
            return true
        }

        return false
    }
}

// MARK: - Safe Array Subscript

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Quote Text Trimming

private extension String {
    /// Trim leading/trailing whitespace and collapse consecutive blank lines into a single newline.
    var trimmedForQuote: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse runs of 2+ newlines (with optional spaces/tabs between) into a single newline
        return trimmed.replacingOccurrences(
            of: "[ \\t]*\\n([ \\t]*\\n)+",
            with: "\n",
            options: .regularExpression
        )
    }
}
