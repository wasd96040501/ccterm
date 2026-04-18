import Foundation
import AgentSDK

// MARK: - ReceiveMode

extension SessionHandle2 {

    /// live 来自 CLI 实时推送；replay 来自 JSONL 历史回放。
    /// 唯一差异：replay 不推进 lifecycle，不触发 hasUnread。
    enum ReceiveMode {
        case live
        case replay
    }
}

// MARK: - Receive

extension SessionHandle2 {

    /// 单一 ingest 入口。吞入一条 Message2：
    /// 1. 识别 tool_result 块 → 原位更新对应 assistant entry 的 `toolResults`，不 append
    /// 2. 过滤不可见消息（synthetic / compact / subagent / 空文本 / 非 user/assistant）
    /// 3. 包为 MessageEntry append 到 `messages`
    /// 4. 副作用：contextUsedTokens/Window、cwd、slashCommands、permissionMode、lifecycle 推进
    ///
    /// live 与 replay 走同一路径。
    func receive(_ message: Message2, mode: ReceiveMode = .live) {
        applyEffects(of: message, mode: mode)

        if let payload = Self.toolResultPayload(in: message) {
            mergeToolResult(toolUseId: payload.toolUseId, result: payload.result)
            return
        }

        guard Self.shouldAppend(message) else { return }

        messages.append(MessageEntry(
            id: UUID(),
            message: message,
            delivery: nil,
            toolResults: [:]
        ))

        if mode == .live, !isFocused {
            hasUnread = true
        }
    }
}

// MARK: - Effects

private extension SessionHandle2 {

    func applyEffects(of message: Message2, mode: ReceiveMode) {
        switch message {
        case .assistant(let m):
            applyAssistantUsage(m)
        case .result(let r):
            applyResult(r, mode: mode)
        case .system(.`init`(let init_)):
            applyInit(init_, mode: mode)
        default:
            break
        }
    }

    func applyAssistantUsage(_ msg: Message2Assistant) {
        guard let usage = msg.message?.usage else { return }
        contextUsedTokens = (usage.inputTokens ?? 0)
            + (usage.cacheCreationInputTokens ?? 0)
            + (usage.cacheReadInputTokens ?? 0)
    }

    func applyResult(_ result: Message2Result, mode: ReceiveMode) {
        let modelUsage: [String: ModelUsageValue]?
        switch result {
        case .success(let s): modelUsage = s.modelUsage
        case .errorDuringExecution(let e): modelUsage = e.modelUsage
        case .unknown: modelUsage = nil
        }
        if let window = modelUsage?.values.compactMap(\.contextWindow).max() {
            contextWindowTokens = window
        }
        if mode == .live, case .responding = status {
            status = .idle
        }
    }

    func applyInit(_ init_: Init, mode: ReceiveMode) {
        if let c = init_.cwd { cwd = c }
        if let cmds = init_.slashCommands {
            slashCommands = cmds.map { SlashCommand(name: $0, description: nil) }
        }
        if let raw = init_.permissionMode, let pm = PermissionMode(rawValue: raw) {
            permissionMode = pm
        }
        if mode == .live, case .starting = status {
            status = .idle
        }
    }
}

// MARK: - Tool result merge

private extension SessionHandle2 {

    struct ToolResultPayload {
        let toolUseId: String
        let result: ItemToolResult
    }

    /// 从 user 消息中提取第一条 tool_result block（通常每条消息只带一个）。
    static func toolResultPayload(in message: Message2) -> ToolResultPayload? {
        guard case .user(let u) = message,
              case .array(let items) = u.message?.content else { return nil }
        for item in items {
            if case .toolResult(let r) = item, let id = r.toolUseId {
                return ToolResultPayload(toolUseId: id, result: r)
            }
        }
        return nil
    }

    func mergeToolResult(toolUseId: String, result: ItemToolResult) {
        guard let idx = indexOfAssistantOwning(toolUseId: toolUseId) else { return }
        var entry = messages[idx]
        entry.toolResults[toolUseId] = result
        messages[idx] = entry
    }

    func indexOfAssistantOwning(toolUseId: String) -> Int? {
        for i in messages.indices.reversed() {
            guard case .assistant(let a) = messages[i].message,
                  let blocks = a.message?.content else { continue }
            if blocks.contains(where: { Self.matchesToolUse($0, id: toolUseId) }) {
                return i
            }
        }
        return nil
    }

    static func matchesToolUse(_ block: Message2AssistantMessageContent, id: String) -> Bool {
        guard case .toolUse(let tu) = block else { return false }
        return (tu.toJSON() as? [String: Any])?["id"] as? String == id
    }
}

// MARK: - Visibility filter

private extension SessionHandle2 {

    /// 是否追加到 timeline。仅 user / assistant 进 timeline；
    /// 并进一步过滤 synthetic / compact / subagent / 空消息 / thinking-only。
    static func shouldAppend(_ message: Message2) -> Bool {
        switch message {
        case .user(let u): return isVisibleUser(u)
        case .assistant(let a): return isVisibleAssistant(a)
        default: return false
        }
    }

    static func isVisibleUser(_ u: Message2User) -> Bool {
        if u.parentToolUseId != nil { return false }
        if u.isSynthetic == true { return false }
        if u.isCompactSummary == true { return false }
        if u.isVisibleInTranscriptOnly == true { return false }
        return hasTextContent(u)
    }

    static func hasTextContent(_ u: Message2User) -> Bool {
        guard let content = u.message?.content else { return false }
        switch content {
        case .string(let s):
            return !s.isEmpty
        case .array(let items):
            return items.contains { item in
                if case .text(let t) = item { return !(t.text?.isEmpty ?? true) }
                return false
            }
        case .other:
            return false
        }
    }

    static func isVisibleAssistant(_ a: Message2Assistant) -> Bool {
        if a.parentToolUseId != nil { return false }
        guard let content = a.message?.content else { return false }
        return content.contains { block in
            switch block {
            case .text(let t): return !(t.text?.isEmpty ?? true)
            case .toolUse: return true
            default: return false
            }
        }
    }
}
