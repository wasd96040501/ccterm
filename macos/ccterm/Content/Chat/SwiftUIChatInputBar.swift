import SwiftUI
import AgentSDK

/// SwiftUI implementation of the Chat InputBar.
struct SwiftUIChatInputBar: View {
    @Bindable var state: ChatSessionViewModel
    let actions: ChatInputBarActions

    private let cornerRadius: CGFloat = 20
    private let buttonSize: CGFloat = 28
    private let animationDuration: TimeInterval = 0.35

    @State private var showFolderPicker = false
    @State private var showBranchPicker = false
    @State private var copiedFeedback: CopiedTarget?
    @Environment(\.colorScheme) private var colorScheme

    private enum CopiedTarget {
        case path, branch
    }

    var body: some View {
        VStack(spacing: 0) {
            mainContainer

            if state.showPathBar {
                pathBar
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: state.showPathBar)
        .transaction { t in
            if state.animationsDisabled { t.disablesAnimations = true }
        }
    }

    // MARK: - Main Container

    private var mainContainer: some View {
        VStack(spacing: 0) {
            overlayContent
            primaryContent
        }
        .frame(maxWidth: .infinity)
        .background(colorScheme == .dark ? .thickMaterial : .bar)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .shadow(color: colorScheme == .light ? .black.opacity(0.1) : .clear,
                radius: 8, x: 0, y: 1)
        .overlay(alignment: .bottomTrailing) {
            actionButtons
                .padding(.trailing, 6)
                .padding(.bottom, 6)
        }
        .overlay(alignment: .top) {
            if !state.isAtBottom {
                scrollToBottomButton
                    .offset(y: -(buttonSize + 8))
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: state.isAtBottom)
        .animation(.smooth(duration: animationDuration), value: state.completion.isActive)
        .animation(.smooth(duration: animationDuration), value: state.isViewingPlan)
        .animation(.smooth(duration: animationDuration), value: state.isInPermissionMode)
        .animation(.smooth(duration: animationDuration), value: state.barState)
        .animation(.smooth(duration: animationDuration), value: state.queuedMessages.count)
        .animation(.smooth(duration: animationDuration), value: state.pendingCommentSelections.count)
    }

    // MARK: - Overlay Content (Completion / Queued Messages)

    @ViewBuilder
    private var overlayContent: some View {
        if state.completion.isActive {
            SwiftUICompletionListView(
                engine: state.completion,
                onConfirm: { _ in
                    state.applyCompletionResult(keepSession: false)
                },
                onDrillDown: { _ in
                    state.applyCompletionResult(keepSession: true)
                },
                onDeleteRecent: { item in
                    guard let dirItem = item as? DirectoryCompletionItem else { return }
                    DirectoryCompletionProvider.removeFromRecent(dirItem.path)
                    state.completion.removeItem(where: { ($0 as? DirectoryCompletionItem)?.path == dirItem.path })
                }
            )
            .transition(.identity)

            Divider()
        } else if showStartingOverlay {
            SwiftUICLIStartingView()
                .transition(.opacity)

            Divider()
        } else if showQueue {
            SwiftUIQueuedMessagesView(
                messages: state.queuedMessages,
                onDelete: { index in
                    state.deleteQueuedMessage(at: index)
                }
            )
            .transition(.identity)

            Divider()
        }
    }

    // MARK: - Primary Content (Input / Permission)

    @ViewBuilder
    private var primaryContent: some View {
        if state.isViewingPlan {
            SwiftUIInputContentView(state: state, actions: actions, isCommentMode: true)
                .transition(.opacity)
        } else if state.isInPermissionMode {
            SwiftUIPermissionOverlayView(
                cards: state.permissionCards,
                currentIndex: $state.currentPermissionCardIndex
            )
            .transition(.opacity)
        } else {
            SwiftUIInputContentView(state: state, actions: actions)
                .opacity(isInputDisabled ? 0.4 : 1.0)
                .allowsHitTesting(!isInputDisabled)
                .transition(.opacity)
        }
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 6) {
            if state.isViewingPlan {
                circleButton(
                    icon: "arrow.up",
                    color: .accentColor,
                    action: { state.sendComment() }
                )
                .opacity(state.canSendComment ? 1.0 : 0.4)
                .disabled(!state.canSendComment)
                .transition(.scale.combined(with: .opacity))
                .hoverTooltip("Command Enter (⌘↩)")
            } else if state.isInPermissionMode {
                // Action buttons are inside each permission card (PermissionActionBar).
                EmptyView()
            } else {
                switch state.barState {
                case .notStarted, .inactive, .idle:
                    circleButton(
                        icon: "arrow.up",
                        color: .accentColor,
                        action: sendAction
                    )
                    .opacity(state.canSend ? 1.0 : 0.4)
                    .disabled(!state.canSend)
                    .transition(.scale.combined(with: .opacity))
                    .hoverTooltip("Command Enter (⌘↩)")

                case .responding:
                    circleButton(
                        icon: "stop.fill",
                        color: Color(nsColor: .systemGray),
                        action: { state.interrupt() }
                    )
                    .transition(.scale.combined(with: .opacity))
                    .hoverTooltip("Escape (⎋)")

                    circleButton(
                        icon: "arrow.up",
                        color: .accentColor,
                        action: queueSendAction
                    )
                    .opacity(state.canSend ? 1.0 : 0.4)
                    .disabled(!state.canSend)
                    .transition(.scale.combined(with: .opacity))
                    .hoverTooltip("Command Enter (⌘↩)")

                case .starting, .interrupting:
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: buttonSize, height: buttonSize)
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: - Path Bar

    @ViewBuilder
    private var pathBar: some View {
        HStack(spacing: 4) {
            directoryButton
            if !state.isDirectoryUnset, let branch = displayBranch, !branch.isEmpty {
                branchButton(branch: branch)
                    .transition(.opacity)
            }
            if showWorktreeButton {
                worktreeButton
                    .transition(.opacity)
            }
            Spacer()
            if let percent = state.contextUsedPercent {
                contextRingButton(percent: percent)
                    .transition(.opacity)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .animation(.smooth(duration: 0.25), value: displayBranch)
        .animation(.smooth(duration: 0.25), value: showWorktreeButton)
        .animation(.smooth(duration: 0.25), value: state.contextUsedPercent != nil)
        .onChange(of: state.selectedDirectory) { _, newDir in
            if let dir = newDir {
                state.branchMonitor.monitor(directory: dir)
            } else {
                state.branchMonitor.stop()
            }
        }
    }

    /// Branch to display: prefer monitor's branch (live), fall back to state.branch (from SessionHandle).
    private var displayBranch: String? {
        state.branchMonitor.branch ?? state.branch
    }

    // MARK: - Directory Button

    @ViewBuilder
    private var directoryButton: some View {
        HStack(spacing: 4) {
            // Main button area
            Button {
                if state.isDirectoryUnset {
                    showFolderPicker = true
                } else if state.isAdditionalPathEditable {
                    showFolderPicker = true
                } else if let dir = state.selectedDirectory {
                    copyToClipboard(dir, target: .path)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: state.isDirectoryUnset ? "folder.badge.plus" : (copiedFeedback == .path ? "checkmark" : "folder"))
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 14, height: 14)
                    if state.isDirectoryUnset {
                        Text("Select Working Directory")
                            .font(.system(size: 12, weight: .medium))
                    } else if let dir = state.selectedDirectory {
                        Text(state.isTempDir ? String(localized: "Temporary Session") : truncatedPath(dir))
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !state.additionalDirectories.isEmpty {
                            Text("+\(state.additionalDirectories.count)")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .hoverCapsule(staticFill: state.isDirectoryUnset ? Color.orange.opacity(0.12) : nil)
        .foregroundStyle(state.isDirectoryUnset ? .orange : .secondary)
        .popover(isPresented: $showFolderPicker) {
            FolderPickerPopover(
                title: String(localized: "Working Directory"),
                description: String(localized: "Select primary directory and additional directories"),
                userDefaultsKey: "folderPickerRecent",
                primaryReadOnly: !state.isPrimaryPathEditable,
                initialPrimary: state.selectedDirectory.map { URL(fileURLWithPath: $0) },
                initialAdditional: Set(state.additionalDirectories.map { URL(fileURLWithPath: $0) })
            ) { primary, additional in
                showFolderPicker = false
                guard let primary else { return }
                state.selectedDirectory = primary.path
                state.additionalDirectories = additional.map(\.path)
                state.branchMonitor.monitor(directory: primary.path)
            }
        }
    }

    // MARK: - Branch Button

    private func branchButton(branch: String) -> some View {
        Button {
            if !state.isWorktree {
                showBranchPicker = true
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 14, height: 14)
                Text(branch)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(HoverCapsuleStyle())
        .popover(isPresented: $showBranchPicker) {
            BranchPickerView(
                branches: GitUtils.listBranches(at: state.selectedDirectory ?? ""),
                currentBranch: displayBranch,
                onSelect: { selectedBranch in
                    guard let dir = state.selectedDirectory else { return }
                    if GitUtils.switchBranch(at: dir, branch: selectedBranch) {
                        state.branchMonitor.monitor(directory: dir)
                    }
                    showBranchPicker = false
                }
            )
        }
    }

    // MARK: - Worktree Button

    private var worktreeButton: some View {
        Button {
            guard isWorktreeEditable else { return }
            state.isWorktree.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .font(.system(size: 12, weight: .medium))
                Text("worktree")
                    .font(.system(size: 12))
            }
            .foregroundStyle(state.isWorktree ? Color.accentColor : .secondary)
        }
        .buttonStyle(HoverCapsuleStyle())
        .disabled(!isWorktreeEditable)
    }

    // MARK: - Context Ring

    private func contextRingButton(percent: Double) -> some View {
        ProgressRingView(
            percent: percent,
            colorThresholds: [(70, .accentColor), (90, .orange), (100, .red)]
        )
        .hoverTooltip(contextRingText)
    }

    // MARK: - Scroll to Bottom

    private var scrollToBottomButton: some View {
        Button {
            state.scrollToBottom()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.secondary)
                .offset(y: 1)
                .frame(width: buttonSize, height: buttonSize)
                .background {
                    Circle()
                        .fill(colorScheme == .dark ? .thickMaterial : .bar)
                }
                .overlay {
                    Circle()
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
                .shadow(color: colorScheme == .light ? .black.opacity(0.1) : .clear,
                        radius: 4, x: 0, y: 1)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var showStartingOverlay: Bool {
        state.barState == .starting
    }

    private var showQueue: Bool {
        !state.queuedMessages.isEmpty && !state.completion.isActive && !state.isInPermissionMode
    }

    private var isInputDisabled: Bool {
        state.barState == .starting || state.barState == .interrupting
    }

    private var isWorktreeEditable: Bool {
        state.barState == .notStarted
    }

    private var showWorktreeButton: Bool {
        if state.isAdditionalPathEditable {
            return state.selectedDirectory.map { GitUtils.isGitRepository(at: $0) } ?? false
        }
        return state.isWorktree
    }

    private var contextRingText: String {
        let used = formatTokenCount(state.contextUsedTokens)
        let total = formatTokenCount(state.contextWindowTokens)
        let pct = Int(state.contextUsedPercent ?? 0)
        return "\(used) / \(total)  (\(pct)%)"
    }

    private func circleButton(icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: buttonSize, height: buttonSize)
                .background(Circle().fill(color))
        }
        .buttonStyle(.plain)
    }

    private func sendAction() {
        guard state.canSend else { return }
        let text = state.trimmedText
        state.deleteDraft()
        actions.onSend(text)
    }

    private func queueSendAction() {
        let text = state.trimmedText
        guard !text.isEmpty else { return }
        state.queueMessage(text)
        state.clearInput()
    }

    private func truncatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        var display = path
        if display.hasPrefix(home) {
            display = "~" + display.dropFirst(home.count)
        }
        let components = display.components(separatedBy: "/").filter { !$0.isEmpty }
        if components.count > 2 {
            return components.suffix(2).joined(separator: "/")
        }
        return display
    }

    private func copyToClipboard(_ text: String, target: CopiedTarget) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedFeedback = target
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedFeedback == target {
                copiedFeedback = nil
            }
        }
    }

    private func formatTokenCount(_ count: Int) -> String {
        let k = Double(count) / 1000.0
        return String(format: "%.1fk", k)
    }
}

// MARK: - Preview

#Preview {
    InputBarPreviewWrapper()
        .frame(minWidth: 960)
        .frame(width: 1200, height: 800)
}

private struct InputBarPreviewWrapper: View {
    @State private var state = ChatSessionViewModel.newConversation(onRouterAction: { _ in })
    @State private var selectedBarState: InputBarState = .notStarted

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                SwiftUIChatInputBar(state: state, actions: ChatInputBarActions())
                    .frame(maxWidth: 860)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
        }
        .onAppear { setupMockState() }
    }

    private func setupMockState() {
        state.selectedDirectory = "/Volumes/largedisk/code/ccterm"
    }
}
