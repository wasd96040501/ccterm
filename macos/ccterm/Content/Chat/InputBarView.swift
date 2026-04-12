import SwiftUI
import AgentSDK

/// InputBar 主容器。直接读 SessionHandle，不经过中间 ViewModel。
struct InputBarView: View {
    @Bindable var handle: SessionHandle
    @Environment(AppViewModel.self) private var appVM

    private let cornerRadius: CGFloat = 20
    private let buttonSize: CGFloat = 28
    private let animationDuration: TimeInterval = 0.35

    @State private var showFolderPicker = false
    @State private var showBranchPicker = false
    @State private var copiedFeedback: CopiedTarget?
    @State private var shimmerPhase: CGFloat = 0
    @State private var completionVM = CompletionViewModel()
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

            if handle.showPathBar {
                pathBar
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: handle.showPathBar)
        .transaction { t in
            if handle.animationsDisabled { t.disablesAnimations = true }
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
            if !handle.isAtBottom {
                scrollToBottomButton
                    .offset(y: -(buttonSize + 8))
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: handle.isAtBottom)
        .animation(.smooth(duration: animationDuration), value: completionVM.isActive)
        .animation(.smooth(duration: animationDuration), value: handle.activePlanReviewId != nil)
        .animation(.smooth(duration: animationDuration), value: !handle.pendingPermissions.isEmpty)
        .animation(.smooth(duration: animationDuration), value: handle.status)
        .animation(.smooth(duration: animationDuration), value: handle.queuedMessages.count)
        .animation(.smooth(duration: animationDuration), value: handle.pendingCommentSelections.count)
    }

    // MARK: - Overlay Content (Completion / Starting / Queued Messages)

    @ViewBuilder
    private var overlayContent: some View {
        if completionVM.isActive {
            CompletionListView(
                viewModel: completionVM,
                onConfirm: { _ in applyCompletionResult(keepSession: false) },
                onDrillDown: { _ in applyCompletionResult(keepSession: true) },
                onDeleteRecent: { item in
                    guard let dirItem = item as? DirectoryCompletionItem else { return }
                    DirectoryCompletionProvider.removeFromRecent(dirItem.path)
                    completionVM.removeItem(where: { ($0 as? DirectoryCompletionItem)?.path == dirItem.path })
                }
            )
            .transition(.identity)

            Divider()
        } else if handle.showStartingOverlay {
            CLIStartingView()
                .transition(.opacity)

            Divider()
        } else if handle.showQueuedMessages && !completionVM.isActive && handle.pendingPermissions.isEmpty {
            QueuedMessagesView(
                messages: handle.queuedMessages,
                onDelete: { index in handle.dequeue(at: index) }
            )
            .transition(.identity)

            Divider()
        }
    }

    // MARK: - Primary Content (Input / Permission / Plan Comment)

    @ViewBuilder
    private var primaryContent: some View {
        if handle.activePlanReviewId != nil {
            PlanCommentInputView(handle: handle)
                .transition(.opacity)
        } else if !handle.pendingPermissions.isEmpty {
            PermissionOverlayView(handle: handle)
                .transition(.opacity)
        } else {
            InputContentView(handle: handle, completionVM: completionVM)
                .opacity(handle.isInputDisabled ? 0.4 : 1.0)
                .allowsHitTesting(!handle.isInputDisabled)
                .transition(.opacity)
        }
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 6) {
            if handle.activePlanReviewId != nil {
                let canSend = !handle.planCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                circleButton(
                    icon: "arrow.up",
                    color: .accentColor,
                    action: { handleCommandReturn() }
                )
                .opacity(canSend ? 1.0 : 0.4)
                .disabled(!canSend)
                .transition(.scale.combined(with: .opacity))
                .hoverTooltip(sendKeyBehavior.shortcutHint)
            } else if !handle.pendingPermissions.isEmpty {
                EmptyView()
            } else {
                switch handle.status {
                case .notStarted, .inactive, .idle:
                    circleButton(
                        icon: "arrow.up",
                        color: .accentColor,
                        action: { handleCommandReturn() }
                    )
                    .opacity(handle.canSend ? 1.0 : 0.4)
                    .disabled(!handle.canSend)
                    .transition(.scale.combined(with: .opacity))
                    .hoverTooltip(sendKeyBehavior.shortcutHint)

                case .responding:
                    circleButton(
                        icon: "stop.fill",
                        color: Color(nsColor: .systemGray),
                        action: { handle.interrupt() }
                    )
                    .transition(.scale.combined(with: .opacity))
                    .hoverTooltip("Escape (⎋)")

                    circleButton(
                        icon: "arrow.up",
                        color: .accentColor,
                        action: { handleCommandReturn() }
                    )
                    .opacity(handle.canSend ? 1.0 : 0.4)
                    .disabled(!handle.canSend)
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

    // MARK: - Command Routing

    private func handleCommandReturn() {
        if handle.activePlanReviewId != nil {
            sendPlanComment()
        } else if !handle.pendingPermissions.isEmpty {
            // Permission card confirm handled by card itself
        } else if handle.status == .responding {
            let trimmed = handle.trimmedDraftText
            guard !trimmed.isEmpty else { return }
            handle.enqueue(trimmed)
            handle.clearDraft()
        } else {
            let trimmed = handle.trimmedDraftText
            guard !trimmed.isEmpty else { return }
            handle.clearDraft()
            appVM.sessionService.submitMessage(handle: handle, text: trimmed)
        }
    }

    private func handleEscape() {
        if completionVM.isActive {
            completionVM.dismiss()
        } else if handle.status == .responding {
            handle.interrupt()
        }
    }

    // MARK: - Plan Comment

    private func sendPlanComment() {
        let text = handle.planCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let reviewId = handle.activePlanReviewId,
              let cardType = appVM.permissionCardTypes[reviewId],
              case .exitPlanMode(let cardVM) = cardType else { return }

        if !handle.pendingCommentSelections.isEmpty {
            for selection in handle.pendingCommentSelections {
                cardVM.commentStore?.addInlineComment(text: text, range: selection)
            }
            handle.pendingCommentSelections.removeAll()
            appVM.planRendererService.clearSelection()
        } else {
            cardVM.commentStore?.addGlobalComment(text: text)
        }
        handle.planCommentText = ""
    }

    // MARK: - Completion

    private func applyCompletionResult(keepSession: Bool) {
        guard var result = completionVM.confirmSelection(keepSession: keepSession) else { return }
        if keepSession, result.replacement.hasSuffix(" ") {
            result.replacement = String(result.replacement.dropLast())
        }
        let nsText = handle.draftText as NSString
        if result.range.location + result.range.length <= nsText.length {
            handle.draftText = nsText.replacingCharacters(in: result.range, with: result.replacement)
        }
    }

    // MARK: - Path Bar

    @ViewBuilder
    private var pathBar: some View {
        HStack(spacing: 4) {
            directoryButton
            if !handle.isDirectoryUnset, let branch = handle.displayBranch, !branch.isEmpty {
                branchButton(branch: branch)
                    .transition(.opacity)
            }
            if handle.showWorktreeButton {
                worktreeButton
                    .transition(.opacity)
            }
            Spacer()
            if let percent = handle.contextUsedPercent {
                contextRingButton(percent: percent)
                    .transition(.opacity)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .animation(.smooth(duration: 0.25), value: handle.displayBranch)
        .animation(.smooth(duration: 0.25), value: handle.showWorktreeButton)
        .animation(.smooth(duration: 0.25), value: handle.isWorktreeEditable)
        .animation(.smooth(duration: 0.25), value: handle.contextUsedPercent != nil)
    }

    // MARK: - Directory Button

    private var isPathInteractive: Bool {
        handle.isDirectoryUnset || handle.isAdditionalPathEditable
    }

    @ViewBuilder
    private var directoryButton: some View {
        HStack(spacing: 4) {
            Button {
                if handle.isDirectoryUnset || handle.isAdditionalPathEditable {
                    showFolderPicker = true
                } else if isPathInteractive, let dir = handle.originPath {
                    copyToClipboard(dir, target: .path)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: handle.isDirectoryUnset ? "folder.badge.plus" : (copiedFeedback == .path ? "checkmark" : "folder"))
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 14, height: 14)
                    if handle.isDirectoryUnset {
                        Text("Select Working Directory")
                            .font(.system(size: 12, weight: .medium))
                    } else if let dir = handle.originPath {
                        Text(handle.isTempDir ? String(localized: "Temporary Session") : truncatedPath(dir))
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !handle.additionalDirectories.isEmpty {
                            Text("+\(handle.additionalDirectories.count)")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .allowsHitTesting(isPathInteractive)
        }
        .hoverCapsule(
            staticFill: handle.isDirectoryUnset ? Color.orange.opacity(0.12) : nil,
            hoverOpacity: isPathInteractive ? 0.08 : 0
        )
        .foregroundStyle(handle.isDirectoryUnset ? .orange : .secondary)
        .popover(isPresented: $showFolderPicker) {
            FolderPickerPopover(
                title: String(localized: "Working Directory"),
                description: String(localized: "Select primary directory and additional directories"),
                userDefaultsKey: "folderPickerRecent",
                primaryReadOnly: !handle.isPrimaryPathEditable,
                initialPrimary: handle.originPath.map { URL(fileURLWithPath: $0) },
                initialAdditional: Set(handle.additionalDirectories.map { URL(fileURLWithPath: $0) })
            ) { primary, additional in
                showFolderPicker = false
                guard let primary else { return }
                handle.originPath = primary.path
                handle.additionalDirectories = additional.map(\.path)
            }
        }
    }

    // MARK: - Branch Button

    private var isBranchInteractive: Bool {
        !(handle.isWorktree && !handle.isWorktreeEditable)
    }

    private func branchButton(branch: String) -> some View {
        let isGenerating = handle.isBranchGenerating
        return Button {
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
            .overlay {
                if isGenerating {
                    shimmerOverlay
                        .clipped()
                }
            }
            .compositingGroup()
        }
        .buttonStyle(isGenerating ? HoverCapsuleStyle(hoverOpacity: 0, pressOpacity: 0) : (isBranchInteractive ? HoverCapsuleStyle() : HoverCapsuleStyle(hoverOpacity: 0, pressOpacity: 0)))
        .allowsHitTesting(!isGenerating && isBranchInteractive)
        .onChange(of: isGenerating) { _, generating in
            if generating {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    shimmerPhase = 1
                }
            } else {
                shimmerPhase = 0
            }
        }
        .popover(isPresented: $showBranchPicker) {
            BranchPickerView(
                branches: GitUtils.listBranches(at: handle.cwd ?? ""),
                currentBranch: handle.displayBranch,
                onSelect: { selectedBranch in
                    if handle.isWorktree && handle.status == .notStarted {
                        handle.worktreeBaseBranch = selectedBranch
                    } else {
                        guard let dir = handle.cwd else { return }
                        if GitUtils.switchBranch(at: dir, branch: selectedBranch) {
                            handle.updateBranchMonitor(directory: dir)
                        }
                    }
                    showBranchPicker = false
                }
            )
        }
    }

    // MARK: - Shimmer Overlay

    private var shimmerOverlay: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .white.opacity(0.4), location: 0.5),
                .init(color: .clear, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: 40)
        .offset(x: shimmerPhase * 160 - 80)
        .blendMode(.sourceAtop)
        .allowsHitTesting(false)
    }

    // MARK: - Worktree Button

    @ViewBuilder
    private var worktreeButton: some View {
        if handle.isWorktreeEditable {
            Menu {
                Button {
                    handle.setWorktree(false)
                } label: {
                    Label(String(localized: "Local Project"), systemImage: "folder")
                    if !handle.isWorktree { Image(systemName: "checkmark") }
                }
                Button {
                    handle.setWorktree(true)
                } label: {
                    Label(String(localized: "New Worktree"), systemImage: "arrow.turn.up.right")
                    if handle.isWorktree { Image(systemName: "checkmark") }
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
            Image(systemName: handle.isWorktree ? "arrow.turn.up.right" : "folder")
                .font(.system(size: 11, weight: .medium))
            Text(handle.isWorktree ? String(localized: "Worktree") : String(localized: "Local Project"))
                .font(.system(size: 11))
            if showChevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .medium))
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    // MARK: - Context Ring

    private func contextRingButton(percent: Double) -> some View {
        ProgressRingView(
            percent: percent,
            colorThresholds: [(70, .accentColor), (90, .orange), (100, .red)]
        )
        .hoverTooltip(handle.contextRingText)
    }

    // MARK: - Scroll to Bottom

    private var scrollToBottomButton: some View {
        Button {
            handle.scrollToBottom()
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
    @State private var appVM = AppViewModel()

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            if let handle = appVM.sessionService.activeHandle {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    InputBarView(handle: handle)
                        .frame(width: 860)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                }
            }
        }
        .environment(appVM)
        .onAppear { appVM.sessionService.activeHandle?.originPath = "/Volumes/largedisk/code/ccterm" }
    }
}
