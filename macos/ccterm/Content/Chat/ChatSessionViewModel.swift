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

// MARK: - ChatInputBarActions

/// 仅传递需要经过 ChatRouter 路由的操作。
struct ChatInputBarActions {
    /// 发送消息。需要 ChatRouter 路由判断（新建/恢复/直发）。
    var onSend: (String) -> Void = { _ in }
}

// MARK: - ChatRouterAction

/// ChatSessionViewModel 需要 ChatRouter 协调的操作意图。
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

// MARK: - ChatSessionViewModel

/// 单个 session 的完整 UI 状态。持有 handle 引用，通过 computed 直读运行时状态，
/// stored 管理本地 UI 状态，action 直调 handle 方法。InputBar 的唯一数据源。
@Observable
@MainActor
final class ChatSessionViewModel {

    // MARK: - Handle Reference

    /// 当前 session 的 handle。nil 表示新对话（尚未启动进程）。
    /// 由 ChatRouter 在 startNewSession 同步阶段赋值。
    var handle: SessionHandle? {
        didSet {
            guard handle !== oldValue else { return }
            subscribeToEvents()
        }
    }

    // MARK: - Session Identity

    /// 预分配的 session ID。新对话创建时即生成，启动进程时沿用。
    let preassignedId: String

    /// handle 存在时读 handle.sessionId，否则读预分配 ID。全生命周期稳定。
    var sessionId: String { handle?.sessionId ?? preassignedId }

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
            } else {
                pluginDirectories = []
            }
        }
    }

    /// 实际工作目录。session 运行中读 handle.cwd，否则读 originPath。
    var cwd: String? { handle?.cwd ?? originPath }

    /// worktree 创建前用户选择的基础分支。
    var worktreeBaseBranch: String?

    /// 有 handle 读 handle.isWorktree，无 handle 读 stored fallback。
    /// setter：handle == nil → 写 _isWorktree；handle != nil → noop。
    var isWorktree: Bool {
        get { handle?.isWorktree ?? _isWorktree }
        set {
            guard isProcessIdle, handle == nil else { return }
            _isWorktree = newValue
        }
    }

    /// 本地 source of truth。有 handle 时直接写 handle.permissionMode（立即生效）+ stdin 通知 CLI 同步；
    /// 无 handle 时写 _permissionMode，启动时通过 SessionConfig 传给 CLI。
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

    var inputText: String = "" {
        didSet { scheduleDraftSave() }
    }
    var cursorLocation: Int = 0
    /// Set after programmatic text replacement to reposition the cursor.
    var desiredCursorPosition: Int?
    var selectedModel: String?
    var selectedEffort: AgentSDK.Effort = .medium
    var additionalDirectories: [String] = []
    var isTempDir: Bool = false
    var isAtBottom: Bool = true
    var animationsDisabled: Bool = false
    var isFocused: Bool = false
    var pluginDirectories: [String] = []
    var pluginDirCount: Int { pluginDirectories.count }

    // MARK: - Animation

    // MARK: - Permission Cards

    var permissionCards: [PermissionCardItem] = []
    var currentPermissionCardIndex: Int = 0
    var isInPermissionMode: Bool { !permissionCards.isEmpty }

    var currentPermissionCard: PermissionCardItem? {
        permissionCards[safe: currentPermissionCardIndex]
    }

    // MARK: - Plan Viewing State

    /// 正在全屏阅读的 plan 对应的 permission request ID。nil = 未在阅读。
    var viewingPlanPermissionId: String?

    var isViewingPlan: Bool { viewingPlanPermissionId != nil }

    /// 当前阅读的 plan 对应的 ExitPlanModeCardViewModel。
    var viewingPlanCardVM: ExitPlanModeCardViewModel? {
        guard let id = viewingPlanPermissionId,
              let card = permissionCards.first(where: { $0.id == id }),
              case .exitPlanMode(let vm) = card.cardType else { return nil }
        return vm
    }

    /// 已引用的文本片段（React 侧 textSelected 事件追加）。
    var pendingCommentSelections: [PlanComment.SelectionRange] = []

    /// Plan 模式搜索状态。
    var planSearchQuery: String = ""
    var planSearchTotal: Int = 0
    var planSearchCurrent: Int = 0

    /// Execute 二次确认弹窗状态。
    var pendingExecuteMode: PlanExecutionMode?
    var showExecuteConfirmation: Bool { pendingExecuteMode != nil }

    /// 评论模式下是否可发送评论。
    var canSendComment: Bool { !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: - Router Callback

    /// 需要 ChatRouter 协调的操作回调。由 ChatRouter 在创建实例时通过 init 注入。
    let onRouterAction: (ChatRouterAction) -> Void

    /// Plan WebView 单例引用，由 ChatRouter 在创建实例时注入。
    weak var planWebViewLoader: PlanWebViewLoader?

    /// TodoSessionCoordinator 引用，用于同步 todo 状态。由 ChatRouter 注入。
    weak var todoSessionCoordinator: TodoSessionCoordinator?

    // MARK: - Process Exit (per-session 隔离)

    var processExitError: ProcessExitError?
    var hasShownExitAlert: Bool = false

    // MARK: - Completion

    let completion = CompletionEngine()

    /// Slash command 提供者。computed，从 handle.slashCommands 构建。
    var slashCommandProvider: ((_ query: String, _ completion: @escaping ([SlashCommandStore.Match]) -> Void) -> Void)? {
        guard let handle, !handle.slashCommands.isEmpty else { return nil }
        let commands = handle.slashCommands
        return { query, cb in
            let matches = commands.map {
                SlashCommandStore.Match(name: $0.name, description: $0.description, rank: 0, isBuiltIn: $0.isBuiltIn)
            }.filter {
                query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
            }
            cb(matches)
        }
    }

    // MARK: - Branch Monitor

    let branchMonitor = GitBranchMonitor()


    // MARK: - Computed Properties

    /// CLI 未运行（无 session 或历史 session）
    var isProcessIdle: Bool { barState == .notStarted || barState == .inactive }

    /// Primary 目录可编辑（仅新会话）
    var isPrimaryPathEditable: Bool { barState == .notStarted }

    /// Additional 目录可编辑（仅新会话，即从未启动过 session）。
    /// inactive 的历史 session 已进入开发，不允许切换目录（点击复制路径）。
    var isAdditionalPathEditable: Bool { barState == .notStarted }

    var isDirectoryUnset: Bool {
        isPrimaryPathEditable && originPath == nil
    }

    var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var trimmedText: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var showPathBar: Bool {
        isPrimaryPathEditable || originPath != nil
    }

    // MARK: - Draft Persistence

    static let newSessionDraftKey = "chatInputBarDraft_new"

    private var draftKey: String {
        handle == nil ? Self.newSessionDraftKey : "chatInputBarDraft_\(sessionId)"
    }

    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?

    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        let key = draftKey
        let text = inputText
        draftSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            if text.isEmpty {
                UserDefaults.standard.removeObject(forKey: key)
            } else {
                UserDefaults.standard.set(text, forKey: key)
            }
        }
    }

    private func loadDraft() {
        inputText = UserDefaults.standard.string(forKey: draftKey) ?? ""
    }

    /// 立即删除 UserDefaults 中的 draft 缓存，不清空 UI 输入框。
    func deleteDraft() {
        draftSaveTask?.cancel()
        UserDefaults.standard.removeObject(forKey: draftKey)
        UserDefaults.standard.removeObject(forKey: Self.newSessionDraftKey)
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
            if new != .starting && new != .idle && new != .interrupting && !inputText.isEmpty {
                clearInput()
            }
        case .permissionsChanged:
            rebuildPermissionCards()
            if let handle, let coordinator = todoSessionCoordinator {
                coordinator.handleStateChange(
                    needsAttention: !handle.pendingPermissions.isEmpty,
                    for: handle.sessionId
                )
            }
        case .processExited(let exit):
            guard exit.exitCode != 0, !hasShownExitAlert else { return }
            hasShownExitAlert = true
            processExitError = ProcessExitError(exitCode: exit.exitCode, stderr: exit.stderr)
        }
    }

    // MARK: - Lifecycle

    private init(preassignedId: String, onRouterAction: @escaping (ChatRouterAction) -> Void) {
        self.preassignedId = preassignedId
        self.onRouterAction = onRouterAction
    }

    // MARK: - Factory Methods

    /// 创建新对话实例。预分配 UUID，handle 为 nil，stored 字段为默认值，draft 从 UserDefaults 恢复。
    static func newConversation(preassignedId: String = UUID().uuidString, onRouterAction: @escaping (ChatRouterAction) -> Void) -> ChatSessionViewModel {
        let vm = ChatSessionViewModel(preassignedId: preassignedId, onRouterAction: onRouterAction)
        vm.loadDraft()
        return vm
    }

    /// 创建已有 session 实例。从 handle 和 SessionRecord 恢复状态。
    init(handle: SessionHandle, record: SessionRecord?, onRouterAction: @escaping (ChatRouterAction) -> Void) {
        self.preassignedId = handle.sessionId
        self.handle = handle
        self.onRouterAction = onRouterAction

        if let record {
            self.originPath = record.originPath ?? record.cwd
            self._isWorktree = record.isWorktree
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
        loadDraft()

        // 恢复 session 时启动 branchMonitor（.onChange 不会对初始值触发）
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

    // MARK: - Permission Cards

    /// 根据 handle.pendingPermissions 重建 permission card ViewModels。
    /// 复用已有 CardVM（保留评论、Radio 选中状态），只为新增 ID 创建新 VM。
    func rebuildPermissionCards() {
        guard let handle else { return }
        let pending = handle.pendingPermissions

        let currentIds = Set(permissionCards.map(\.id))
        let newIds = Set(pending.map(\.id))
        guard currentIds != newIds else { return }

        NSLog("[PlanDebug] rebuildPermissionCards: old=%@ new=%@", currentIds.sorted().description, newIds.sorted().description)

        let existingByID = Dictionary(uniqueKeysWithValues: permissionCards.map { ($0.id, $0) })

        // Detect removed ids and clearPlan for them
        let removedIds = currentIds.subtracting(newIds)
        for removedId in removedIds {
            planWebViewLoader?.clearPlan(key: removedId)
        }

        permissionCards = pending.map { permission in
            if let existing = existingByID[permission.id] {
                return existing
            }

            let cardType = PermissionCardViewModelFactory.make(
                for: permission.request,
                onDecision: { decision in permission.respond(decision) },
                onNewSession: { [weak self] in
                    guard let self, let handle = self.handle else { return }
                    let plan = Self.extractPlan(from: permission.request)
                    let planFilePath = Self.extractPlanFilePath(from: permission.request)
                    self.onRouterAction(.executePlan(PlanRequest(sourceHandle: handle, plan: plan, planFilePath: planFilePath)))
                }
            )

            NSLog("[PlanDebug] rebuildPermissionCards: NEW card id=%@ toolName=%@ cardType=%@", permission.id, permission.request.toolName, String(describing: cardType))

            if case .exitPlanMode(let vm) = cardType {
                NSLog("[PlanDebug]   exitPlanMode hasPlan=%@", String(describing: vm.hasPlan))
                vm.onViewPlan = { [weak self] in
                    self?.enterPlanView(permissionId: permission.id)
                }
                vm.onExecute = { [weak self] mode in
                    self?.executePlan(mode: mode)
                }

                // Push plan markdown to singleton loader
                if let md = vm.planMarkdown, !md.isEmpty {
                    let planKey = permission.id
                    planWebViewLoader?.setPlan(key: planKey, markdown: md)

                    // Wire commentStore callbacks (带 key)
                    vm.commentStore?.onCommentsChanged = { [weak self] comments in
                        self?.planWebViewLoader?.setComments(key: planKey, comments: comments)
                    }
                    // Push persisted comments if any
                    if let store = vm.commentStore, !store.comments.isEmpty {
                        planWebViewLoader?.setComments(key: planKey, comments: store.comments)
                    }
                }
            }

            return PermissionCardItem(id: permission.id, cardType: cardType)
        }
        currentPermissionCardIndex = 0

        // If viewing plan was removed, exit fullscreen
        if let viewingId = viewingPlanPermissionId,
           !permissionCards.contains(where: { $0.id == viewingId }) {
            viewingPlanPermissionId = nil
            pendingCommentSelections.removeAll()
        }
    }

    // MARK: - Text Operations

    /// 清空输入框并删除 draft。
    func clearInput() {
        deleteDraft()
        inputText = ""
    }

    func focusTextView() {
        isFocused = true
    }

    func applyCompletionResult(keepSession: Bool) {
        guard var result = completion.confirmSelection(keepSession: keepSession) else { return }

        if keepSession, result.replacement.hasSuffix(" ") {
            result.replacement = String(result.replacement.dropLast())
        }

        let nsText = inputText as NSString
        if result.range.location + result.range.length <= nsText.length {
            let newCursor = result.range.location + result.replacement.count
            inputText = nsText.replacingCharacters(in: result.range, with: result.replacement)
            cursorLocation = newCursor
            desiredCursorPosition = newCursor
        }
    }

    func tryConfirmCompletionFromInput() -> Bool {
        guard let range = completion.tryConfirmFromInput() else { return false }

        let nsText = inputText as NSString
        if range.location + range.length <= nsText.length {
            inputText = nsText.replacingCharacters(in: range, with: "")
            cursorLocation = range.location
            desiredCursorPosition = range.location
        }
        return true
    }

    // MARK: - Plan Actions

    func enterPlanView(permissionId: String) {
        NSLog("[PlanDebug] enterPlanView id=%@", permissionId)
        NSLog("[PlanDebug]   permissionCards.count=%d ids=%@", permissionCards.count, permissionCards.map(\.id).description)
        planWebViewLoader?.switchPlan(key: permissionId)
        viewingPlanPermissionId = permissionId
    }

    func exitPlanView() {
        viewingPlanPermissionId = nil
        pendingCommentSelections.removeAll()
        planSearchQuery = ""
        planSearchTotal = 0
        planSearchCurrent = 0
        pendingExecuteMode = nil
    }

    func executePlan(mode: PlanExecutionMode) {
        guard let vm = viewingPlanCardVM ?? currentPlanCardVM else { return }
        let requestId = vm.request.requestId
        exitPlanView()
        PlanCommentStore.cleanup(permissionRequestId: requestId)
        switch mode {
        case .clearContextAutoAccept:
            vm.executeNewSession()
        case .autoAcceptEdits:
            vm.executeAllow()
            permissionMode = .acceptEdits
        case .manualApprove:
            vm.executeAllow()
        }
    }

    /// 当前 permission cards 中的 ExitPlanMode card（不要求处于 plan 全屏）。
    private var currentPlanCardVM: ExitPlanModeCardViewModel? {
        for card in permissionCards {
            if case .exitPlanMode(let vm) = card.cardType { return vm }
        }
        return nil
    }

    func rejectPlan() {
        guard let vm = viewingPlanCardVM else { return }
        let requestId = vm.request.requestId
        exitPlanView()
        PlanCommentStore.cleanup(permissionRequestId: requestId)
        vm.executeDeny()
    }

    func revisePlan() {
        guard let vm = viewingPlanCardVM, let store = vm.commentStore else { return }
        let feedback = store.assembleFeedback()
        let requestId = vm.request.requestId
        exitPlanView()
        PlanCommentStore.cleanup(permissionRequestId: requestId)
        vm.executeDenyWithFeedback(feedback)
    }

    func sendComment() {
        let text = trimmedText
        guard !text.isEmpty, let cardVM = viewingPlanCardVM else { return }

        if !pendingCommentSelections.isEmpty {
            for selection in pendingCommentSelections {
                cardVM.commentStore?.addInlineComment(text: text, range: selection)
            }
            pendingCommentSelections.removeAll()
            planWebViewLoader?.clearSelection()
        } else {
            cardVM.commentStore?.addGlobalComment(text: text)
        }
        clearInput()
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

// MARK: - CompletionEngine

@Observable
final class CompletionEngine {

    // MARK: - Public State

    enum EmptyReason {
        case loading
        case noMatches
        case noDirectory
    }

    var items: [any CompletionItem] = []
    var selectedIndex: Int = 0
    var isLoading: Bool = false
    var emptyReason: EmptyReason = .noMatches

    /// Cursor location in the text, written by the input view.
    var cursorLocation: Int = 0

    var hasSession: Bool { activeSession != nil }

    /// Completion list is visible when a session exists and cursor is within the trigger word.
    var isActive: Bool {
        guard let session = activeSession else { return false }
        if session.emptyReasonOverride == .noDirectory { return true }
        let range = wordRange(for: session)
        return cursorLocation > session.anchorLocation && cursorLocation <= range.upperBound
    }

    var headerText: String? { activeSession?.headerText }
    var anchorLocation: Int? { activeSession?.anchorLocation }

    /// Whether the active session supports Space-key input validation (e.g. directory pick).
    var hasInputValidation: Bool { activeSession?.validateAndConfirmFromInput != nil }

    // MARK: - Internal State

    private var activeSession: CompletionSession?
    private var text: String = ""
    private var lastQuery: String?
    private var generation: Int = 0
    private var debounceTask: Task<Void, Never>?

    private let rules: [any CompletionTriggerRule] = [
        SlashCommandTriggerRule(),
        DirectoryPickTriggerRule(),   // before FileMention: both match "@", directoryPick only when dir==nil
        FileMentionTriggerRule(),
    ]

    // MARK: - CompletionSession

    struct CompletionSession {
        let anchorLocation: Int
        let headerText: String?
        /// Override for empty reason (e.g. `.noDirectory` for slash without provider).
        let emptyReasonOverride: EmptyReason?
        let provider: (_ query: String, _ completion: @escaping ([any CompletionItem]) -> Void) -> Void
        /// Returns text replacement. `keepSession` lets the session distinguish navigation (Tab) from final confirm (Enter).
        /// The `wordEnd` parameter is the end offset of the full trigger word (anchor to next whitespace/EOT).
        let makeReplacement: (_ item: any CompletionItem, _ text: String, _ wordEnd: Int, _ keepSession: Bool) -> (range: NSRange, replacement: String)
        /// Side-effect closure called on final confirm (keepSession=false). Nil for standard text replacement.
        let onItemConfirmed: ((_ item: any CompletionItem) -> Void)?
        /// Validates raw query text (e.g. typed path) and performs side-effects if valid. Returns true if confirmed.
        let validateAndConfirmFromInput: ((_ query: String) -> Bool)?
        /// Custom word range calculation. Returns anchor..<wordEnd. Nil to use default whitespace-based logic.
        let customWordRange: ((_ text: String, _ anchorLocation: Int) -> Range<Int>)?
        /// Transform extracted query before passing to provider (e.g. strip quotes). Nil for identity.
        let transformQuery: ((_ rawQuery: String) -> String)?

        init(anchorLocation: Int,
             headerText: String? = nil,
             emptyReasonOverride: EmptyReason? = nil,
             provider: @escaping (_ query: String, _ completion: @escaping ([any CompletionItem]) -> Void) -> Void,
             makeReplacement: @escaping (_ item: any CompletionItem, _ text: String, _ wordEnd: Int, _ keepSession: Bool) -> (range: NSRange, replacement: String),
             onItemConfirmed: ((_ item: any CompletionItem) -> Void)? = nil,
             validateAndConfirmFromInput: ((_ query: String) -> Bool)? = nil,
             customWordRange: ((_ text: String, _ anchorLocation: Int) -> Range<Int>)? = nil,
             transformQuery: ((_ rawQuery: String) -> String)? = nil) {
            self.anchorLocation = anchorLocation
            self.headerText = headerText
            self.emptyReasonOverride = emptyReasonOverride
            self.provider = provider
            self.makeReplacement = makeReplacement
            self.onItemConfirmed = onItemConfirmed
            self.validateAndConfirmFromInput = validateAndConfirmFromInput
            self.customWordRange = customWordRange
            self.transformQuery = transformQuery
        }
    }

    // MARK: - Word Extraction

    /// Extract the full word after the anchor (from anchor+1 to wordEnd), optionally transformed.
    private func extractQuery(for session: CompletionSession) -> String? {
        let range = wordRange(for: session)
        guard range.upperBound > range.lowerBound + 1 else { return range.upperBound > range.lowerBound ? "" : nil }
        let start = text.index(text.startIndex, offsetBy: range.lowerBound + 1)
        let end = text.index(text.startIndex, offsetBy: range.upperBound)
        let raw = String(text[start..<end])
        if let transform = session.transformQuery {
            return transform(raw)
        }
        return raw
    }

    /// Range of the trigger word in the text: [anchor ... wordEnd].
    /// `wordEnd` is the offset past the last character of the word (like cursor convention).
    private func wordRange(for session: CompletionSession) -> Range<Int> {
        if let custom = session.customWordRange {
            return custom(text, session.anchorLocation)
        }
        return defaultWordRange(anchor: session.anchorLocation)
    }

    /// Default word range: anchor to next whitespace or end of text.
    private func defaultWordRange(anchor: Int) -> Range<Int> {
        guard anchor < text.count else { return anchor..<anchor }
        let afterAnchor = text.index(text.startIndex, offsetBy: anchor + 1)
        let rest = text[afterAnchor...]
        if let spaceIdx = rest.firstIndex(where: { $0.isWhitespace || $0.isNewline }) {
            return anchor..<text.distance(from: text.startIndex, to: spaceIdx)
        }
        return anchor..<text.count
    }

    // MARK: - Trigger Detection

    /// Called when text changes. Detects triggers and updates query.
    func checkTrigger(text newText: String, cursorLocation: Int, hasMarkedText: Bool, context: CompletionTriggerContext) {
        guard !hasMarkedText else { return }
        text = newText
        self.cursorLocation = cursorLocation

        guard cursorLocation >= 0, cursorLocation <= text.count else {
            if activeSession != nil { dismiss() }
            return
        }

        // Detect new trigger at current cursor position
        let newSession = detectTrigger(text: text, cursorLocation: cursorLocation, context: context)

        if let active = activeSession {
            // New trigger at a different anchor → replace session
            if let newSession, newSession.anchorLocation != active.anchorLocation {
                dismiss()
                startSession(newSession)
                return
            }

            // Anchor character deleted → dismiss
            if active.anchorLocation >= text.count {
                dismiss()
                if let newSession { startSession(newSession) }
                return
            }

            // Text changed — re-query with full word
            refreshQuery()
            return
        }

        // No active session → start new if trigger found
        if let newSession {
            startSession(newSession)
        }
    }

    /// Iterate trigger rules and return first matching session, or nil.
    private func detectTrigger(text: String, cursorLocation: Int, context: CompletionTriggerContext) -> CompletionSession? {
        guard cursorLocation > 0 else { return nil }
        for rule in rules {
            if let session = rule.match(text: text, cursorLocation: cursorLocation, context: context) {
                return session
            }
        }
        return nil
    }

    private func startSession(_ session: CompletionSession) {
        activeSession = session
        lastQuery = nil

        if let override = session.emptyReasonOverride {
            emptyReason = override
            items = []
            isLoading = false
            if override == .noDirectory { return }
        }

        refreshQuery()
    }

    // MARK: - Query Refresh

    /// Re-extract the full word query from text and call provider if query changed.
    private func refreshQuery() {
        guard let session = activeSession else { return }

        // Anchor out of bounds → dismiss
        guard session.anchorLocation < text.count else {
            dismiss()
            return
        }

        let query = extractQuery(for: session) ?? ""

        // Skip provider call if query hasn't changed
        guard query != lastQuery else { return }
        lastQuery = query

        generation += 1
        let currentGen = generation
        debounceTask?.cancel()

        if query.isEmpty {
            session.provider(query) { [weak self] results in
                DispatchQueue.main.async {
                    guard let self, self.generation == currentGen else { return }
                    self.items = results
                    self.selectedIndex = 0
                    self.isLoading = false
                    self.emptyReason = results.isEmpty ? (session.emptyReasonOverride ?? .noMatches) : .noMatches
                }
            }
        } else {
            debounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, let self, self.generation == currentGen else { return }

                let loadingTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    guard !Task.isCancelled, let self, self.generation == currentGen else { return }
                    self.isLoading = true
                    self.emptyReason = .loading
                }

                session.provider(query) { [weak self] results in
                    DispatchQueue.main.async {
                        loadingTask.cancel()
                        guard let self, self.generation == currentGen else { return }
                        self.items = results
                        self.selectedIndex = 0
                        self.isLoading = false
                        self.emptyReason = results.isEmpty ? (session.emptyReasonOverride ?? .noMatches) : .noMatches
                    }
                }
            }
        }
    }

    // MARK: - Confirm

    func confirmSelection(keepSession: Bool = false) -> (range: NSRange, replacement: String)? {
        guard let session = activeSession,
              selectedIndex >= 0, selectedIndex < items.count else { return nil }

        let item = items[selectedIndex]
        let wEnd = wordRange(for: session).upperBound
        let result = session.makeReplacement(item, text, wEnd, keepSession)

        if !keepSession {
            session.onItemConfirmed?(item)
            dismiss()
        }
        return result
    }

    func tryConfirmFromInput() -> NSRange? {
        guard let session = activeSession,
              let validate = session.validateAndConfirmFromInput else { return nil }

        guard let query = extractQuery(for: session), !query.isEmpty else { return nil }
        guard validate(query) else { return nil }

        let wEnd = wordRange(for: session).upperBound
        let range = NSRange(location: session.anchorLocation, length: wEnd - session.anchorLocation)
        dismiss()
        return range
    }

    // MARK: - Item Mutation

    /// Remove items matching a predicate and adjust selectedIndex.
    func removeItem(where predicate: (any CompletionItem) -> Bool) {
        items.removeAll(where: predicate)
        if selectedIndex >= items.count {
            selectedIndex = max(0, items.count - 1)
        }
    }

    // MARK: - Navigation

    func moveSelectionUp() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
    }

    func moveSelectionDown() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % items.count
    }

    // MARK: - Dismiss

    func dismiss() {
        activeSession = nil
        lastQuery = nil
        items = []
        selectedIndex = 0
        isLoading = false
        generation += 1
        debounceTask?.cancel()
        debounceTask = nil
    }
}
