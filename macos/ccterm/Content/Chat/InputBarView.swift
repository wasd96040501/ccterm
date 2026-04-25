import SwiftUI
import AgentSDK

/// InputBar 主容器 —— 直接绑定 `SessionHandle2`,无中间 ViewModel。
/// `SessionHandle2` 是单一可观察 source of truth,本 view 仅承担纯 UI 状态
/// (popover 展开 / shimmer 相位 / draft 文本 / copy 反馈 等)。
struct InputBarView: View {

    @Bindable var handle: SessionHandle2

    private let cornerRadius: CGFloat = 20
    private let buttonSize: CGFloat = 28
    private let animationDuration: TimeInterval = 0.35

    @State private var draftText: String = ""
    @State private var isInputFocused: Bool = false
    @State private var desiredCursorPosition: Int? = nil

    @State private var showFolderPicker = false
    @State private var showBranchPicker = false
    @State private var copiedFeedback: CopiedTarget?
    @State private var shimmerPhase: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("sendKeyBehavior") private var sendKeyBehaviorRaw: String = SendKeyBehavior.commandEnter.rawValue

    private var sendKeyBehavior: SendKeyBehavior {
        SendKeyBehavior(rawValue: sendKeyBehaviorRaw) ?? .commandEnter
    }

    private enum CopiedTarget { case path, branch }

    // MARK: - Status helpers

    private var status: SessionHandle2.Status { handle.status }
    private var isProcessIdle: Bool { status == .notStarted || status == .stopped }
    private var isPrimaryPathEditable: Bool { status == .notStarted }
    private var isAdditionalPathEditable: Bool { status == .notStarted }
    private var isWorktreeEditable: Bool { status == .notStarted }
    private var isInputDisabled: Bool { status == .starting || status == .interrupting }
    private var showStartingOverlay: Bool { status == .starting }
    private var hasPendingPermission: Bool { !handle.pendingPermissions.isEmpty }

    private var isDirectoryUnset: Bool {
        isPrimaryPathEditable && handle.originPath == nil && handle.cwd == nil
    }

    private var showPathBar: Bool {
        isPrimaryPathEditable || handle.originPath != nil || handle.cwd != nil
    }

    private var displayPath: String? { handle.originPath ?? handle.cwd }

    private var displayBranch: String? {
        if handle.isGeneratingTitle {
            return String(localized: "Generating branch…")
        }
        return handle.worktreeBranch
    }

    private var contextUsedPercent: Double? {
        guard handle.contextWindowTokens > 0 else { return nil }
        return Double(handle.contextUsedTokens) / Double(handle.contextWindowTokens) * 100
    }

    private var contextRingText: String {
        let used = formatTokenCount(handle.contextUsedTokens)
        let total = formatTokenCount(handle.contextWindowTokens)
        let pct = Int(contextUsedPercent ?? 0)
        return "\(used) / \(total)  (\(pct)%)"
    }

    private var canSend: Bool {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isPrimaryPathEditable && handle.originPath == nil && handle.cwd == nil {
            return false
        }
        return true
    }

    private var isWorktreeGitDir: Bool {
        guard let dir = handle.originPath else { return false }
        return GitUtils.isGitRepository(at: dir)
    }

    private var showWorktreeButton: Bool {
        if isAdditionalPathEditable {
            return isWorktreeGitDir
        }
        return handle.isWorktree
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            mainContainer
            if showPathBar {
                pathBar
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: showPathBar)
        .onAppear { loadDraft() }
        .onChange(of: handle.sessionId) { _, _ in loadDraft() }
        .onChange(of: draftText) { _, newValue in saveDraft(newValue) }
    }

    // MARK: - Main container

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
        .animation(.smooth(duration: animationDuration), value: status)
        .animation(.smooth(duration: animationDuration), value: hasPendingPermission)
    }

    // MARK: - Overlay (starting only — completion / queued 在 v2 暂未接)

    @ViewBuilder
    private var overlayContent: some View {
        if showStartingOverlay {
            CLIStartingView()
                .transition(.opacity)
            Divider()
        }
    }

    // MARK: - Primary content

    @ViewBuilder
    private var primaryContent: some View {
        if hasPendingPermission {
            PermissionOverlayView(pendingPermissions: handle.pendingPermissions)
                .transition(.opacity)
        } else {
            InputContentView(
                handle: handle,
                draftText: $draftText,
                isInputFocused: $isInputFocused,
                desiredCursorPosition: $desiredCursorPosition,
                onCommandReturn: send,
                onEscape: handleEscape
            )
            .opacity(isInputDisabled ? 0.4 : 1.0)
            .allowsHitTesting(!isInputDisabled)
            .transition(.opacity)
        }
    }

    // MARK: - Action buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 6) {
            if hasPendingPermission {
                EmptyView()
            } else {
                switch status {
                case .notStarted, .stopped, .idle:
                    sendButton
                case .responding:
                    interruptButton
                    sendButton
                case .starting, .interrupting:
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: buttonSize, height: buttonSize)
                        .transition(.opacity)
                }
            }
        }
    }

    private var sendButton: some View {
        circleButton(icon: "arrow.up", color: .accentColor, action: send)
            .opacity(canSend ? 1.0 : 0.4)
            .disabled(!canSend)
            .transition(.scale.combined(with: .opacity))
            .hoverTooltip(sendKeyBehavior.shortcutHint)
    }

    private var interruptButton: some View {
        circleButton(icon: "stop.fill", color: Color(nsColor: .systemGray)) {
            handle.interrupt()
        }
        .transition(.scale.combined(with: .opacity))
        .hoverTooltip("Escape (⎋)")
    }

    // MARK: - Path bar

    @ViewBuilder
    private var pathBar: some View {
        HStack(spacing: 4) {
            directoryButton
            if !isDirectoryUnset, let branch = displayBranch, !branch.isEmpty {
                branchButton(branch: branch)
                    .transition(.opacity)
            }
            if showWorktreeButton {
                worktreeButton
                    .transition(.opacity)
            }
            Spacer()
            if let percent = contextUsedPercent {
                contextRingButton(percent: percent)
                    .transition(.opacity)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .animation(.smooth(duration: 0.25), value: displayBranch)
        .animation(.smooth(duration: 0.25), value: showWorktreeButton)
        .animation(.smooth(duration: 0.25), value: isWorktreeEditable)
        .animation(.smooth(duration: 0.25), value: contextUsedPercent != nil)
    }

    // MARK: - Directory button

    private var isPathInteractive: Bool {
        isDirectoryUnset || isAdditionalPathEditable
    }

    @ViewBuilder
    private var directoryButton: some View {
        HStack(spacing: 4) {
            Button {
                if isDirectoryUnset || isAdditionalPathEditable {
                    showFolderPicker = true
                } else if isPathInteractive, let dir = displayPath {
                    copyToClipboard(dir, target: .path)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isDirectoryUnset
                          ? "folder.badge.plus"
                          : (copiedFeedback == .path ? "checkmark" : "folder"))
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 14, height: 14)
                    if isDirectoryUnset {
                        Text("Select Working Directory")
                            .font(.system(size: 12, weight: .medium))
                    } else if let dir = displayPath {
                        Text(truncatedPath(dir))
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
            staticFill: isDirectoryUnset ? Color.orange.opacity(0.12) : nil,
            hoverOpacity: isPathInteractive ? 0.08 : 0
        )
        .foregroundStyle(isDirectoryUnset ? .orange : .secondary)
        .popover(isPresented: $showFolderPicker) {
            FolderPickerPopover(
                title: String(localized: "Working Directory"),
                description: String(localized: "Select primary directory and additional directories"),
                userDefaultsKey: "folderPickerRecent",
                primaryReadOnly: !isPrimaryPathEditable,
                initialPrimary: handle.originPath.map { URL(fileURLWithPath: $0) },
                initialAdditional: Set(handle.additionalDirectories.map { URL(fileURLWithPath: $0) })
            ) { primary, additional in
                showFolderPicker = false
                guard let primary else { return }
                handle.setOriginPath(primary.path)
                handle.setAdditionalDirectories(additional.map(\.path))
            }
        }
    }

    // MARK: - Branch button

    private var isBranchInteractive: Bool {
        !(handle.isWorktree && !isWorktreeEditable)
    }

    private func branchButton(branch: String) -> some View {
        let isGenerating = handle.isGeneratingTitle
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
                    shimmerOverlay.clipped()
                }
            }
            .compositingGroup()
        }
        .buttonStyle(isGenerating
                     ? HoverCapsuleStyle(hoverOpacity: 0, pressOpacity: 0)
                     : (isBranchInteractive ? HoverCapsuleStyle()
                                            : HoverCapsuleStyle(hoverOpacity: 0, pressOpacity: 0)))
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
                branches: GitUtils.listBranches(at: handle.cwd ?? handle.originPath ?? ""),
                currentBranch: displayBranch,
                onSelect: { selected in
                    if handle.isWorktree, status == .notStarted {
                        handle.setWorktreeBranch(selected)
                    } else if let dir = handle.cwd ?? handle.originPath {
                        _ = GitUtils.switchBranch(at: dir, branch: selected)
                    }
                    showBranchPicker = false
                }
            )
        }
    }

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

    // MARK: - Worktree button

    @ViewBuilder
    private var worktreeButton: some View {
        if isWorktreeEditable {
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

    // MARK: - Context ring

    private func contextRingButton(percent: Double) -> some View {
        ProgressRingView(
            percent: percent,
            colorThresholds: [(70, .accentColor), (90, .orange), (100, .red)]
        )
        .hoverTooltip(contextRingText)
    }

    // MARK: - Send / Escape

    private func send() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // 新对话第一条消息触发 title 生成(空 title 时)
        let shouldGenerateTitle = handle.title.isEmpty && handle.status == .notStarted
        handle.send(text: text)
        if shouldGenerateTitle {
            handle.generateTitle(from: text)
        }
        draftText = ""
        UserDefaults.standard.removeObject(forKey: draftKey)
    }

    private func handleEscape() {
        if status == .responding {
            handle.interrupt()
        }
    }

    // MARK: - Draft persistence

    private var draftKey: String { "chatInputBarDraft_\(handle.sessionId)" }

    private func loadDraft() {
        draftText = UserDefaults.standard.string(forKey: draftKey) ?? ""
    }

    private func saveDraft(_ text: String) {
        if text.isEmpty {
            UserDefaults.standard.removeObject(forKey: draftKey)
        } else {
            UserDefaults.standard.set(text, forKey: draftKey)
        }
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

    private func formatTokenCount(_ count: Int) -> String {
        let k = Double(count) / 1000.0
        return String(format: "%.1fk", k)
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
