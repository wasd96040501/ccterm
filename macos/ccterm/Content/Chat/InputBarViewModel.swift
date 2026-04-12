import SwiftUI
import Observation
import AgentSDK

// MARK: - InputBarState

enum InputBarState: Equatable {
    case notStarted    // 无 session，可选目录/effort/model
    case inactive      // 历史 session（CLI 未运行），可选目录/effort/model
    case idle          // CLI 运行中，等待用户输入
    case starting      // CLI 启动中，所有控件禁用
    case responding    // 模型生成中，可中断/queue
    case interrupting  // 中断中，所有控件禁用
}

// MARK: - ChatRouterAction

/// InputBarViewModel 需要 ChatRouter 协调的操作意图。
enum ChatRouterAction {
    case executePlan(PlanRequest)
}

enum PlanExecutionMode {
    case clearContextAutoAccept
    case autoAcceptEdits
    case manualApprove
}

struct PlanRequest {
    let sourceHandle: SessionHandle
    let plan: String
    let planFilePath: String?
}

// MARK: - ProcessExitError

/// 进程退出错误，用于 SwiftUI .alert(item:) 展示。
struct ProcessExitError: Identifiable {
    let id = UUID()
    let exitCode: Int32
    let stderr: String?
}

// PermissionCardItem is defined in PermissionCardTypes.swift

// MARK: - InputBarViewModel

/// InputBar 的路由层。持有子 ViewModel（inputVM / permissionVM / planReviewVM），
/// 桥接 handle 运行时状态，处理模式路由和事件分发。
@Observable
@MainActor
final class InputBarViewModel {

    // MARK: - Handle Reference

    /// 当前 session 的 handle。nil 表示新对话（尚未启动进程）。
    /// 由 ChatRouter 在 startNewSession 同步阶段赋值。
    var handle: SessionHandle? {
        didSet {
            guard handle !== oldValue else { return }
            inputVM.handle = handle
            subscribeToEvents()
        }
    }

    // MARK: - Session Identity

    /// 预分配的 session ID。新对话创建时即生成，启动进程时沿用。
    let preassignedId: String

    /// handle 存在时读 handle.sessionId，否则读预分配 ID。全生命周期稳定。
    var sessionId: String { handle?.sessionId ?? preassignedId }

    // MARK: - Sub ViewModels

    var inputVM: InputViewModel
    var permissionVM: PermissionViewModel
    var planReviewVM: PlanReviewViewModel

    // MARK: - Runtime State (computed, 直读 handle)

    /// InputBar 的展示状态。handle 为 nil 时 .notStarted，否则映射 handle.status。
    var barState: InputBarState {
        guard let handle else { return .notStarted }
        switch handle.status {
        case .inactive:     return .inactive
        case .starting:     return .starting
        case .idle:         return .idle
        case .responding:   return .responding
        case .interrupting: return .interrupting
        }
    }

    var queuedMessages: [String] { handle?.queuedMessages ?? [] }

    var contextUsedPercent: Double? {
        guard let handle, handle.contextWindowTokens > 0 else { return nil }
        return Double(handle.contextUsedTokens) / Double(handle.contextWindowTokens) * 100
    }

    var contextUsedTokens: Int { handle?.contextUsedTokens ?? 0 }
    var contextWindowTokens: Int { handle?.contextWindowTokens ?? 0 }

    // MARK: - Dual-Source Properties

    private var _isWorktree: Bool = false
    private var _permissionMode: PermissionMode = .default

    /// 用户选的原始目录。展示用，不随 worktree 变化。
    var originPath: String? {
        didSet {
            if let dir = originPath {
                pluginDirectories = PluginDirStore.enabledDirectories(forPath: dir)
                updateBranchMonitor(directory: dir)
            } else {
                pluginDirectories = []
                branchMonitor.stop()
            }
        }
    }

    /// 实际工作目录。session 运行中读 handle.cwd，否则读 originPath。
    var cwd: String? { handle?.cwd ?? originPath }

    /// worktree 创建前用户选择的基础分支。
    var worktreeBaseBranch: String?

    /// 有 handle 读 handle.isWorktree，无 handle 读 stored fallback。
    var isWorktree: Bool {
        get { handle?.isWorktree ?? _isWorktree }
        set {
            guard isProcessIdle, handle == nil else { return }
            _isWorktree = newValue
        }
    }

    /// 本地 source of truth。
    var permissionMode: PermissionMode {
        get { handle?.permissionMode ?? _permissionMode }
        set {
            guard barState != .starting else { return }
            if let handle {
                handle.permissionMode = newValue
                handle.setPermissionMode(newValue)
            }
            _permissionMode = newValue
        }
    }

    // MARK: - Local UI State (stored)

    var selectedModel: String?
    var selectedEffort: AgentSDK.Effort = .medium
    var additionalDirectories: [String] = []
    var isTempDir: Bool = false
    var isAtBottom: Bool = true
    var animationsDisabled: Bool = false
    var pluginDirectories: [String] = []
    var pluginDirCount: Int { pluginDirectories.count }

    // MARK: - Router Callback

    /// 需要 ChatRouter 协调的操作回调。由 ChatRouter 在创建实例时通过 init 注入。
    let onRouterAction: (ChatRouterAction) -> Void

    /// 发送消息闭包。由 ChatRouter 在创建时注入。
    let onSend: (String) -> Void

    /// Plan WebView 单例引用，由 ChatRouter 在创建实例时注入。
    weak var planWebViewLoader: PlanWebViewLoader?

    // MARK: - Process Exit (per-session 隔离)

    var processExitError: ProcessExitError?
    var hasShownExitAlert: Bool = false

    // MARK: - Branch Monitor

    let branchMonitor = GitBranchMonitor()

    // MARK: - Computed Properties (从 View 搬入)

    /// CLI 未运行（无 session 或历史 session）
    var isProcessIdle: Bool { barState == .notStarted || barState == .inactive }

    /// Primary 目录可编辑（仅新会话）
    var isPrimaryPathEditable: Bool { barState == .notStarted }

    /// Additional 目录可编辑（仅新会话）。
    var isAdditionalPathEditable: Bool { barState == .notStarted }

    var isDirectoryUnset: Bool {
        isPrimaryPathEditable && originPath == nil
    }

    var showPathBar: Bool {
        isPrimaryPathEditable || originPath != nil
    }

    /// 文本输入框/按钮禁用
    var isInputDisabled: Bool {
        barState == .starting || barState == .interrupting
    }

    var showStartingOverlay: Bool {
        barState == .starting
    }

    var showQueuedMessages: Bool {
        !queuedMessages.isEmpty && !inputVM.completionVM.isActive && !permissionVM.isActive
    }

    var isWorktreeEditable: Bool {
        barState == .notStarted
    }

    var showWorktreeButton: Bool {
        if isAdditionalPathEditable {
            return originPath.map { GitUtils.isGitRepository(at: $0) } ?? false
        }
        return isWorktree
    }

    /// Branch to display: worktree 未启动时展示用户选的 baseBranch，否则展示 monitor 实时值。
    var displayBranch: String? {
        if isWorktree && barState == .notStarted, let base = worktreeBaseBranch {
            return base
        }
        return branchMonitor.branch
    }

    var contextRingText: String {
        let used = formatTokenCount(contextUsedTokens)
        let total = formatTokenCount(contextWindowTokens)
        let pct = Int(contextUsedPercent ?? 0)
        return "\(used) / \(total)  (\(pct)%)"
    }

    var isEffortSupported: Bool {
        !CLICapabilityStore.shared.supportedEffortLevels(for: selectedModel).isEmpty
    }

    func formatTokenCount(_ count: Int) -> String {
        let k = Double(count) / 1000.0
        return String(format: "%.1fk", k)
    }

    // MARK: - Event Subscription

    @ObservationIgnored private var eventTask: Task<Void, Never>?

    private func subscribeToEvents() {
        eventTask?.cancel()
        guard let handle else { return }
        eventTask = Task { [weak self] in
            for await event in handle.eventStream() {
                guard let self else { return }
                self.handleEvent(event)
            }
        }
    }

    private func handleEvent(_ event: SessionEvent) {
        switch event {
        case .statusChanged(_, let new):
            if new == .responding && !inputVM.text.isEmpty {
                inputVM.clearInput()
            }
        case .permissionsChanged:
            if let handle {
                permissionVM.rebuild(from: handle.pendingPermissions, handle: handle)
                planReviewVM.handlePermissionCardsUpdated()
            }
        case .processExited(let exit):
            guard exit.exitCode != 0, !hasShownExitAlert else { return }
            hasShownExitAlert = true
            processExitError = ProcessExitError(exitCode: exit.exitCode, stderr: exit.stderr)
        case .cwdChanged(let newDir):
            updateBranchMonitor(directory: newDir)
        }
    }

    // MARK: - Lifecycle

    private init(
        preassignedId: String,
        onRouterAction: @escaping (ChatRouterAction) -> Void,
        onSend: @escaping (String) -> Void,
        planWebViewLoader: PlanWebViewLoader?
    ) {
        self.preassignedId = preassignedId
        self.onRouterAction = onRouterAction
        self.onSend = onSend
        self.planWebViewLoader = planWebViewLoader

        // Create sub VMs
        self.inputVM = InputViewModel(sessionId: preassignedId, handle: nil)

        // Placeholder closures — will be wired after self is available
        self.permissionVM = PermissionViewModel(
            planWebViewLoader: planWebViewLoader,
            onRouterAction: onRouterAction,
            onViewPlan: { _ in },
            onExecutePlan: { _ in }
        )
        self.planReviewVM = PlanReviewViewModel(
            planWebViewLoader: planWebViewLoader,
            setPermissionMode: { _ in },
            getPermissionCards: { [] }
        )

        // Wire closures that need self
        permissionVM.onViewPlan = { [weak self] permissionId in
            self?.planReviewVM.enter(permissionId: permissionId)
        }
        permissionVM.onExecutePlan = { [weak self] mode in
            self?.planReviewVM.executePlan(mode: mode)
        }
        planReviewVM.setPermissionMode = { [weak self] mode in
            self?.permissionMode = mode
        }
        planReviewVM.getPermissionCards = { [weak self] in
            self?.permissionVM.cards ?? []
        }
    }

    // MARK: - Factory Methods

    /// 创建新对话实例。预分配 UUID，handle 为 nil，stored 字段为默认值，draft 从 UserDefaults 恢复。
    static func newConversation(
        preassignedId: String = UUID().uuidString,
        onRouterAction: @escaping (ChatRouterAction) -> Void,
        onSend: @escaping (String) -> Void = { _ in },
        planWebViewLoader: PlanWebViewLoader? = nil
    ) -> InputBarViewModel {
        let vm = InputBarViewModel(
            preassignedId: preassignedId,
            onRouterAction: onRouterAction,
            onSend: onSend,
            planWebViewLoader: planWebViewLoader
        )
        vm.inputVM.loadDraft()
        return vm
    }

    /// 创建已有 session 实例。从 handle 和 SessionRecord 恢复状态。
    init(
        handle: SessionHandle,
        record: SessionRecord?,
        onRouterAction: @escaping (ChatRouterAction) -> Void,
        onSend: @escaping (String) -> Void,
        planWebViewLoader: PlanWebViewLoader? = nil
    ) {
        self.preassignedId = handle.sessionId
        self.handle = handle
        self.onRouterAction = onRouterAction
        self.onSend = onSend
        self.planWebViewLoader = planWebViewLoader

        // Create sub VMs
        self.inputVM = InputViewModel(sessionId: handle.sessionId, handle: handle)

        // Placeholder closures
        self.permissionVM = PermissionViewModel(
            planWebViewLoader: planWebViewLoader,
            onRouterAction: onRouterAction,
            onViewPlan: { _ in },
            onExecutePlan: { _ in }
        )
        self.planReviewVM = PlanReviewViewModel(
            planWebViewLoader: planWebViewLoader,
            setPermissionMode: { _ in },
            getPermissionCards: { [] }
        )

        // Wire closures
        permissionVM.onViewPlan = { [weak self] permissionId in
            self?.planReviewVM.enter(permissionId: permissionId)
        }
        permissionVM.onExecutePlan = { [weak self] mode in
            self?.planReviewVM.executePlan(mode: mode)
        }
        planReviewVM.setPermissionMode = { [weak self] mode in
            self?.permissionMode = mode
        }
        planReviewVM.getPermissionCards = { [weak self] in
            self?.permissionVM.cards ?? []
        }

        if let record {
            self.originPath = record.originPath ?? record.cwd
            self._isWorktree = record.isWorktree
            handle.isWorktree = record.isWorktree
            self.additionalDirectories = record.extra.addDirs ?? []
            self.pluginDirectories = record.extra.pluginDirs ?? []
            self.isTempDir = record.isTempDir
            if let mode = record.extra.permissionMode.flatMap({ PermissionMode(rawValue: $0) }) {
                self._permissionMode = mode
            }
            self.selectedModel = record.extra.model
            if let effortRaw = record.extra.effort, let effort = Effort(rawValue: effortRaw) {
                self.selectedEffort = effort
            }
        }

        subscribeToEvents()
        inputVM.loadDraft()

        // 恢复 session 时启动 branchMonitor
        if let dir = handle.cwd ?? record?.cwd {
            branchMonitor.monitor(directory: dir)
        }
    }

    // MARK: - User Actions (直调 handle)

    func interrupt() {
        handle?.interrupt()
    }

    func scrollToBottom() {
        handle?.bridge?.scrollToBottom()
    }

    func queueMessage(_ text: String) {
        handle?.enqueue(text)
    }

    func deleteQueuedMessage(at index: Int) {
        handle?.dequeue(at: index)
    }

    func selectPermissionMode(_ mode: PermissionMode) {
        permissionMode = mode
    }

    func cyclePermissionMode() {
        let modes = PermissionMode.allCases
            .filter { $0 != .auto || CLICapabilityStore.shared.supportsAutoMode(for: selectedModel) }
        guard let idx = modes.firstIndex(of: permissionMode) else { return }
        let next = modes[(idx + 1) % modes.count]
        selectPermissionMode(next)
    }

    func selectModel(_ model: String?) {
        selectedModel = model
        handle?.setModel(model)
        reconcileCapabilitiesForModel(model)
    }

    func selectEffort(_ effort: Effort) {
        selectedEffort = effort
        handle?.setEffort(effort)
    }

    func setWorktree(_ value: Bool) {
        guard isProcessIdle, handle == nil else { return }
        _isWorktree = value
    }

    func focusDirectoryPicker() {
        // Handled by view-level folder picker UI
    }

    // MARK: - Branch Monitor

    func updateBranchMonitor(directory: String? = nil) {
        if let dir = directory ?? cwd {
            branchMonitor.monitor(directory: dir)
        } else {
            branchMonitor.stop()
        }
    }

    // MARK: - Mode Routing

    /// Command+Return / Enter 路由。按模式分发到对应子 VM。
    func handleCommandReturn() {
        if planReviewVM.isActive {
            planReviewVM.sendComment()
        } else if permissionVM.isActive {
            if let card = permissionVM.currentCard, card.cardType.canConfirm {
                card.cardType.confirm()
            }
        } else if barState == .responding {
            inputVM.queueSend(handle: handle)
        } else if let text = inputVM.prepareSend() {
            onSend(text)
        }
    }

    /// Escape 路由。
    func handleEscape() {
        if inputVM.completionVM.isActive {
            inputVM.completionVM.dismiss()
        } else if barState == .responding {
            interrupt()
        }
    }

    // MARK: - Capabilities Reconciliation

    /// 切换模型后，将不支持的 effort / permission mode 兜底到默认值。
    private func reconcileCapabilitiesForModel(_ modelValue: String?) {
        let store = CLICapabilityStore.shared
        let supportedLevels = store.supportedEffortLevels(for: modelValue)
        if !supportedLevels.isEmpty && !supportedLevels.contains(selectedEffort) {
            selectEffort(.medium)
        }
        if permissionMode == .auto && !store.supportsAutoMode(for: modelValue) {
            selectPermissionMode(.default)
        }
    }

    // MARK: - Plan Extraction

    static func extractPlan(from request: PermissionRequest) -> String {
        if case .ExitPlanMode(let v) = request.toolInput {
            return v.input?.plan ?? ""
        }
        return ""
    }

    static func extractPlanFilePath(from request: PermissionRequest) -> String? {
        return nil
    }
}
