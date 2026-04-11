import SwiftUI
import AgentSDK

/// InputBar 主容器。
struct InputBarView: View {
    @Bindable var viewModel: InputBarViewModel

    private let cornerRadius: CGFloat = 20
    private let buttonSize: CGFloat = 28
    private let animationDuration: TimeInterval = 0.35

    @State private var showFolderPicker = false
    @State private var showBranchPicker = false
    @State private var copiedFeedback: CopiedTarget?
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("sendKeyBehavior") private var sendKeyBehaviorRaw: String = SendKeyBehavior.commandEnter.rawValue

    private var sendKeyBehavior: SendKeyBehavior {
        SendKeyBehavior(rawValue: sendKeyBehaviorRaw) ?? .commandEnter
    }

    private enum CopiedTarget {
        case path, branch
    }

    var body: some View {
        VStack(spacing: 0) {
            mainContainer

            if viewModel.showPathBar {
                pathBar
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: viewModel.showPathBar)
        .transaction { t in
            if viewModel.animationsDisabled { t.disablesAnimations = true }
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
            if !viewModel.isAtBottom {
                scrollToBottomButton
                    .offset(y: -(buttonSize + 8))
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: viewModel.isAtBottom)
        .animation(.smooth(duration: animationDuration), value: viewModel.inputVM.completionVM.isActive)
        .animation(.smooth(duration: animationDuration), value: viewModel.planReviewVM.isActive)
        .animation(.smooth(duration: animationDuration), value: viewModel.permissionVM.isActive)
        .animation(.smooth(duration: animationDuration), value: viewModel.barState)
        .animation(.smooth(duration: animationDuration), value: viewModel.queuedMessages.count)
        .animation(.smooth(duration: animationDuration), value: viewModel.planReviewVM.pendingCommentSelections.count)
    }

    // MARK: - Overlay Content (Completion / Queued Messages)

    @ViewBuilder
    private var overlayContent: some View {
        if viewModel.inputVM.completionVM.isActive {
            CompletionListView(
                viewModel: viewModel.inputVM.completionVM,
                onConfirm: { _ in
                    viewModel.inputVM.applyCompletionResult(keepSession: false)
                },
                onDrillDown: { _ in
                    viewModel.inputVM.applyCompletionResult(keepSession: true)
                },
                onDeleteRecent: { item in
                    guard let dirItem = item as? DirectoryCompletionItem else { return }
                    DirectoryCompletionProvider.removeFromRecent(dirItem.path)
                    viewModel.inputVM.completionVM.removeItem(where: { ($0 as? DirectoryCompletionItem)?.path == dirItem.path })
                }
            )
            .transition(.identity)

            Divider()
        } else if viewModel.showStartingOverlay {
            CLIStartingView()
                .transition(.opacity)

            Divider()
        } else if viewModel.showQueuedMessages {
            QueuedMessagesView(
                messages: viewModel.queuedMessages,
                onDelete: { index in
                    viewModel.deleteQueuedMessage(at: index)
                }
            )
            .transition(.identity)

            Divider()
        }
    }

    // MARK: - Primary Content (Input / Permission / Plan Comment)

    @ViewBuilder
    private var primaryContent: some View {
        if viewModel.planReviewVM.isActive {
            PlanCommentInputView(viewModel: viewModel.planReviewVM)
                .transition(.opacity)
        } else if viewModel.permissionVM.isActive {
            PermissionOverlayView(viewModel: viewModel.permissionVM)
                .transition(.opacity)
        } else {
            InputContentView(viewModel: viewModel)
                .opacity(viewModel.isInputDisabled ? 0.4 : 1.0)
                .allowsHitTesting(!viewModel.isInputDisabled)
                .transition(.opacity)
        }
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 6) {
            if viewModel.planReviewVM.isActive {
                circleButton(
                    icon: "arrow.up",
                    color: .accentColor,
                    action: { viewModel.handleCommandReturn() }
                )
                .opacity(viewModel.planReviewVM.canSendComment ? 1.0 : 0.4)
                .disabled(!viewModel.planReviewVM.canSendComment)
                .transition(.scale.combined(with: .opacity))
                .hoverTooltip(sendKeyBehavior.shortcutHint)
            } else if viewModel.permissionVM.isActive {
                EmptyView()
            } else {
                switch viewModel.barState {
                case .notStarted, .inactive, .idle:
                    circleButton(
                        icon: "arrow.up",
                        color: .accentColor,
                        action: { viewModel.handleCommandReturn() }
                    )
                    .opacity(viewModel.inputVM.canSend ? 1.0 : 0.4)
                    .disabled(!viewModel.inputVM.canSend)
                    .transition(.scale.combined(with: .opacity))
                    .hoverTooltip(sendKeyBehavior.shortcutHint)

                case .responding:
                    circleButton(
                        icon: "stop.fill",
                        color: Color(nsColor: .systemGray),
                        action: { viewModel.handleEscape() }
                    )
                    .transition(.scale.combined(with: .opacity))
                    .hoverTooltip("Escape (⎋)")

                    circleButton(
                        icon: "arrow.up",
                        color: .accentColor,
                        action: { viewModel.handleCommandReturn() }
                    )
                    .opacity(viewModel.inputVM.canSend ? 1.0 : 0.4)
                    .disabled(!viewModel.inputVM.canSend)
                    .transition(.scale.combined(with: .opacity))
                    .hoverTooltip(sendKeyBehavior.shortcutHint)

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
            if !viewModel.isDirectoryUnset, let branch = viewModel.displayBranch, !branch.isEmpty {
                branchButton(branch: branch)
                    .transition(.opacity)
            }
            if viewModel.showWorktreeButton {
                worktreeButton
                    .transition(.opacity)
            }
            Spacer()
            if let percent = viewModel.contextUsedPercent {
                contextRingButton(percent: percent)
                    .transition(.opacity)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .animation(.smooth(duration: 0.25), value: viewModel.displayBranch)
        .animation(.smooth(duration: 0.25), value: viewModel.showWorktreeButton)
        .animation(.smooth(duration: 0.25), value: viewModel.isWorktreeEditable)
        .animation(.smooth(duration: 0.25), value: viewModel.contextUsedPercent != nil)
    }

    // MARK: - Directory Button

    @ViewBuilder
    private var directoryButton: some View {
        HStack(spacing: 4) {
            Button {
                if viewModel.isDirectoryUnset {
                    showFolderPicker = true
                } else if viewModel.isAdditionalPathEditable {
                    showFolderPicker = true
                } else if let dir = viewModel.originPath {
                    copyToClipboard(dir, target: .path)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.isDirectoryUnset ? "folder.badge.plus" : (copiedFeedback == .path ? "checkmark" : "folder"))
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 14, height: 14)
                    if viewModel.isDirectoryUnset {
                        Text("Select Working Directory")
                            .font(.system(size: 12, weight: .medium))
                    } else if let dir = viewModel.originPath {
                        Text(viewModel.isTempDir ? String(localized: "Temporary Session") : truncatedPath(dir))
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !viewModel.additionalDirectories.isEmpty {
                            Text("+\(viewModel.additionalDirectories.count)")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .hoverCapsule(staticFill: viewModel.isDirectoryUnset ? Color.orange.opacity(0.12) : nil)
        .foregroundStyle(viewModel.isDirectoryUnset ? .orange : .secondary)
        .popover(isPresented: $showFolderPicker) {
            FolderPickerPopover(
                title: String(localized: "Working Directory"),
                description: String(localized: "Select primary directory and additional directories"),
                userDefaultsKey: "folderPickerRecent",
                primaryReadOnly: !viewModel.isPrimaryPathEditable,
                initialPrimary: viewModel.originPath.map { URL(fileURLWithPath: $0) },
                initialAdditional: Set(viewModel.additionalDirectories.map { URL(fileURLWithPath: $0) })
            ) { primary, additional in
                showFolderPicker = false
                guard let primary else { return }
                viewModel.originPath = primary.path
                viewModel.additionalDirectories = additional.map(\.path)
            }
        }
    }

    // MARK: - Branch Button

    private func branchButton(branch: String) -> some View {
        Button {
            showBranchPicker = true
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
                branches: GitUtils.listBranches(at: viewModel.cwd ?? ""),
                currentBranch: viewModel.displayBranch,
                onSelect: { selectedBranch in
                    if viewModel.isWorktree && viewModel.barState == .notStarted {
                        viewModel.worktreeBaseBranch = selectedBranch
                    } else {
                        guard let dir = viewModel.cwd else { return }
                        if GitUtils.switchBranch(at: dir, branch: selectedBranch) {
                            viewModel.updateBranchMonitor(directory: dir)
                        }
                    }
                    showBranchPicker = false
                }
            )
        }
    }

    // MARK: - Worktree Button

    @ViewBuilder
    private var worktreeButton: some View {
        if viewModel.isWorktreeEditable {
            Menu {
                Button {
                    viewModel.isWorktree = false
                } label: {
                    Label(String(localized: "Local Project"), systemImage: "folder")
                    if !viewModel.isWorktree { Image(systemName: "checkmark") }
                }
                Button {
                    viewModel.isWorktree = true
                } label: {
                    Label(String(localized: "New Worktree"), systemImage: "arrow.turn.up.right")
                    if viewModel.isWorktree { Image(systemName: "checkmark") }
                }
            } label: {
                worktreeLabel(showChevron: true)
            }
            .buttonStyle(.plain)
        } else {
            worktreeLabel(showChevron: false)
        }
    }

    private func worktreeLabel(showChevron: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: viewModel.isWorktree ? "arrow.turn.up.right" : "folder")
                .font(.system(size: 11, weight: .medium))
            Text(viewModel.isWorktree ? String(localized: "Worktree") : String(localized: "Local Project"))
                .font(.system(size: 11))
            if showChevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .medium))
            }
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - Context Ring

    private func contextRingButton(percent: Double) -> some View {
        ProgressRingView(
            percent: percent,
            colorThresholds: [(70, .accentColor), (90, .orange), (100, .red)]
        )
        .hoverTooltip(viewModel.contextRingText)
    }

    // MARK: - Scroll to Bottom

    private var scrollToBottomButton: some View {
        Button {
            viewModel.scrollToBottom()
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
}

// MARK: - Preview

#Preview {
    InputBarPreviewWrapper()
        .frame(minWidth: 960)
        .frame(width: 1200, height: 800)
}

private struct InputBarPreviewWrapper: View {
    @State private var viewModel = InputBarViewModel.newConversation(onRouterAction: { _ in })

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                InputBarView(viewModel: viewModel)
                    .frame(width: 860)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
        }
        .onAppear { viewModel.originPath = "/Volumes/largedisk/code/ccterm" }
    }
}
