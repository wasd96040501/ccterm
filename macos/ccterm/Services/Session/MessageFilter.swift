import Foundation
import AgentSDK

// MARK: - Shared Types (migrated from MessageProcessor)

/// process/filter 返回的副作用，由调用方决定如何应用。
nonisolated struct MessageProcessorEffects {
    /// sessionInit 到达时携带的信息。
    var sessionInit: SessionInitInfo?
    /// context token 使用量更新。
    var contextUsed: Int?
    /// context window 大小更新（从 result 消息）。
    var contextWindow: Int?
    /// 是否收到 result 消息（表示一轮结束）。
    var turnEnded: Bool = false
    /// enterWorktree/exitWorktree 完成时的路径变更。
    var pathChange: PathChangeEffect?
}

nonisolated struct PathChangeEffect {
    let cwd: String
    let isWorktree: Bool
}

nonisolated struct SessionInitInfo {
    let cwd: String?
    let slashCommands: [String]?
    let permissionMode: String?
}

/// 上下文 token 使用量快照，从历史回放中提取。
nonisolated struct ContextUsageSnapshot {
    let usedTokens: Int
    let windowTokens: Int
}

// MARK: - MessageFilter

/// 纯过滤器：判断 Message2 是否应转发到 React，并提取副作用。不做消息转换。
/// 新路径使用：SessionHandle → MessageFilter → bridge.forwardRawMessage → React adapter。
/// nonisolated：可在任意线程安全调用（历史回放在后台线程执行）。
nonisolated enum MessageFilter {

    nonisolated struct Result {
        let shouldForward: Bool
        let effects: MessageProcessorEffects
    }

    /// 过滤器最小状态。仅追踪 context usage 计算所需的字段。
    nonisolated struct State {
        var lastUsage: MessageUsage?
        var lastModel: String?
        var lastResultMessage: Success?
        /// 缓存各模型的 context window 大小。从 result 消息的 modelUsage 中提取。
        var modelContextWindows: [String: Int] = [:]
    }

    /// 纯函数：判断消息是否应转发，提取副作用。
    nonisolated static func filter(_ message: Message2, state: inout State) -> Result {
        var effects = MessageProcessorEffects()

        switch message {
        case .user(let userMsg):
            return filterUser(userMsg, effects: &effects)

        case .assistant(let assistantMsg):
            return filterAssistant(assistantMsg, state: &state, effects: &effects)

        case .result(let resultMsg):
            return filterResult(resultMsg, state: &state, effects: &effects)

        case .system(let sys):
            return filterSystem(sys, effects: &effects)

        default:
            return Result(shouldForward: false, effects: effects)
        }
    }

    // MARK: - User

    private static func filterUser(
        _ userMsg: Message2User,
        effects: inout MessageProcessorEffects
    ) -> Result {
        // 子 agent 消息忽略
        guard userMsg.parentToolUseId == nil else {
            return Result(shouldForward: false, effects: effects)
        }

        // 合成/压缩/仅转录消息
        guard userMsg.isSynthetic != true else {
            return Result(shouldForward: false, effects: effects)
        }
        guard userMsg.isCompactSummary != true else {
            return Result(shouldForward: false, effects: effects)
        }
        guard userMsg.isVisibleInTranscriptOnly != true else {
            return Result(shouldForward: false, effects: effects)
        }

        // tool_result：直接检查 result object 类型判断是否隐藏
        if userMsg.sourceToolUseId != nil || extractToolUseId(from: userMsg.message?.content) != nil {
            if case .object(let obj) = userMsg.toolUseResult {
                switch obj {
                case .ToolSearch, .TodoWrite, .ExitPlanMode:
                    return Result(shouldForward: false, effects: effects)
                case .EnterWorktree(let o, _):
                    if let worktreePath = o.worktreePath {
                        effects.pathChange = PathChangeEffect(cwd: worktreePath, isWorktree: true)
                    }
                    return Result(shouldForward: false, effects: effects)
                case .ExitWorktree(let o, _):
                    if let originalCwd = o.originalCwd {
                        effects.pathChange = PathChangeEffect(cwd: originalCwd, isWorktree: false)
                    }
                    return Result(shouldForward: false, effects: effects)
                default:
                    break
                }
            }
            // 非隐藏 tool_result → 转发
            return Result(shouldForward: true, effects: effects)
        }

        // plan 消息
        if hasPlanContent(userMsg) {
            return Result(shouldForward: true, effects: effects)
        }

        // xmlContent 忽略（字符串内容以 XML 标签开头）
        if case .string(let s) = userMsg.message?.content, s.hasPrefix("<") {
            return Result(shouldForward: false, effects: effects)
        }

        // 空文本忽略
        guard hasNonEmptyText(userMsg) else {
            return Result(shouldForward: false, effects: effects)
        }

        return Result(shouldForward: true, effects: effects)
    }

    // MARK: - Assistant

    private static func filterAssistant(
        _ assistantMsg: Message2Assistant,
        state: inout State,
        effects: inout MessageProcessorEffects
    ) -> Result {
        guard assistantMsg.parentToolUseId == nil else {
            return Result(shouldForward: false, effects: effects)
        }

        // 提取 context usage 副作用（usage 嵌套在 message 内）
        if let usage = assistantMsg.message?.usage {
            state.lastUsage = usage
            state.lastModel = assistantMsg.message?.model
            let inputTokens = (usage.inputTokens ?? 0) + (usage.cacheCreationInputTokens ?? 0) + (usage.cacheReadInputTokens ?? 0)
            effects.contextUsed = inputTokens

            // 用缓存的 context window 填充（result 到达前就能显示 ring）
            if let model = state.lastModel,
               let cachedWindow = state.modelContextWindows[model] {
                effects.contextWindow = cachedWindow
            }
        }

        return Result(shouldForward: true, effects: effects)
    }

    // MARK: - Result

    private static func filterResult(
        _ resultMsg: Message2Result,
        state: inout State,
        effects: inout MessageProcessorEffects
    ) -> Result {
        effects.turnEnded = true

        switch resultMsg {
        case .success(let s):
            state.lastResultMessage = s
            cacheModelContextWindows(from: s.modelUsage, state: &state)
            if let window = contextWindowSize(from: s.modelUsage) {
                effects.contextWindow = window
            }
        case .errorDuringExecution(let e):
            cacheModelContextWindows(from: e.modelUsage, state: &state)
            if let window = contextWindowSize(from: e.modelUsage) {
                effects.contextWindow = window
            }
        default:
            break
        }

        return Result(shouldForward: true, effects: effects)
    }

    // MARK: - System

    private static func filterSystem(
        _ sys: System,
        effects: inout MessageProcessorEffects
    ) -> Result {
        switch sys {
        case .`init`(let initMsg):
            effects.sessionInit = SessionInitInfo(
                cwd: initMsg.cwd,
                slashCommands: initMsg.slashCommands,
                permissionMode: initMsg.permissionMode
            )
            return Result(shouldForward: false, effects: effects)

        case .turnDuration:
            return Result(shouldForward: true, effects: effects)

        case .taskProgress:
            return Result(shouldForward: true, effects: effects)

        case .taskNotification:
            return Result(shouldForward: true, effects: effects)

        default:
            return Result(shouldForward: false, effects: effects)
        }
    }

    // MARK: - Inline Helpers (nonisolated 版本，避免依赖 @MainActor 的 MessageProcessor)

    private static func extractToolUseId(from content: Message2UserMessageContent?) -> String? {
        guard case .array(let items) = content else { return nil }
        for item in items {
            if case .toolResult(let result) = item {
                return result.toolUseId
            }
        }
        return nil
    }

    private static let planContentPrefix = "Implement the following plan:\n\n"

    private static func hasPlanContent(_ userMsg: Message2User) -> Bool {
        if let planContent = userMsg.planContent, !planContent.isEmpty {
            return true
        }
        guard case .string(let s) = userMsg.message?.content,
              s.hasPrefix(planContentPrefix) else {
            return false
        }
        return s.count > planContentPrefix.count
    }

    private static let interruptedMessages: Set<String> = [
        "[Request interrupted by user]",
        "[Request interrupted by user for tool use]",
    ]

    private static func hasNonEmptyText(_ userMsg: Message2User) -> Bool {
        guard let content = userMsg.message?.content else { return false }
        switch content {
        case .string(let s):
            return s.components(separatedBy: "\n")
                .contains { !interruptedMessages.contains($0) && !$0.isEmpty }
        case .array(let items):
            return items.contains { item in
                guard case .text(let t) = item,
                      let text = t.text,
                      !interruptedMessages.contains(text),
                      !text.isEmpty else { return false }
                return true
            }
        case .other:
            return false
        }
    }

    private static func cacheModelContextWindows(from modelUsage: [String: ModelUsageValue]?, state: inout State) {
        guard let modelUsage else { return }
        for (model, value) in modelUsage {
            if let window = value.contextWindow {
                state.modelContextWindows[model] = window
            }
        }
    }

    static func contextWindowSize(from modelUsage: [String: ModelUsageValue]?, forModel modelName: String? = nil) -> Int? {
        guard let modelUsage else { return nil }

        // 1. Exact match
        if let name = modelName, let window = modelUsage[name]?.contextWindow {
            return window
        }

        // 2. Prefix match (e.g. "claude-opus-4-6" matches "claude-opus-4-6[1m]")
        if let name = modelName {
            for (key, info) in modelUsage {
                guard key.hasPrefix(name), let window = info.contextWindow else { continue }
                return window
            }
        }

        // 3. Fallback: largest contextWindow across all models
        return modelUsage.values.compactMap(\.contextWindow).max()
    }
}

// MARK: - FilterState ContextUsageSnapshot

extension MessageFilter.State {
    /// 从过滤器状态提取 context usage 快照（历史回放用）。
    nonisolated var contextUsageSnapshot: ContextUsageSnapshot? {
        guard let lastUsage else { return nil }
        let used = (lastUsage.inputTokens ?? 0) + (lastUsage.cacheCreationInputTokens ?? 0) + (lastUsage.cacheReadInputTokens ?? 0)
        // 优先从 result 消息取 contextWindow，fallback 到缓存
        let window: Int
        if let resultMsg = lastResultMessage,
           let w = MessageFilter.contextWindowSize(from: resultMsg.modelUsage) {
            window = w
        } else if let model = lastModel, let w = modelContextWindows[model] {
            window = w
        } else {
            window = modelContextWindows.values.max() ?? 0
        }
        guard window > 0 else { return nil }
        return ContextUsageSnapshot(usedTokens: used, windowTokens: window)
    }
}
