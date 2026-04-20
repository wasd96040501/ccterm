import Foundation
import AgentSDK

// MARK: - ReceiveMode

extension SessionHandle2 {

    /// live 来自 CLI 实时推送；replay 来自 JSONL 历史回放。
    /// 唯一差异：replay 不推进 lifecycle，不置 hasUnread。
    enum ReceiveMode { case live, replay }
}

// MARK: - receive

extension SessionHandle2 {

    /// 单一 ingest 入口。吞一条 Message2 并更新 handle：
    /// - 同步副作用（usage、contextWindow、cwd、slashCommands、permissionMode、lifecycle）
    /// - user echo 带 uuid 命中本地 `.queued` entry → 切 `.confirmed`，并推进 status
    /// - tool_result 原位合并到对应 assistant entry，或按可见性追加 MessageEntry
    ///
    /// live 与 replay 走同一路径；`mode` 仅影响 lifecycle 推进与 hasUnread 触发。
    func receive(_ message: Message2, mode: ReceiveMode = .live) {
        switch message {
        case .assistant(let a): noteUsage(a.message?.usage)
        case .result(let r): finishTurn(with: r, mode: mode)
        case .system(.`init`(let info)): adopt(info, mode: mode)
        default: break
        }

        switch action(for: message) {
        case .merge(let id, let result): attachToolResult(result, to: id)
        case .confirm(let id): confirmQueuedEntry(id: id, mode: mode)
        case .append: appendToTimeline(message, mode: mode)
        case .skip: break
        }
    }
}

// MARK: - Dispatch

private extension SessionHandle2 {

    enum Action {
        case merge(toolUseId: String, result: ItemToolResult)
        /// 本地 `.queued` entry 命中 CLI echo（按 uuid 匹配），切 `.confirmed`。
        case confirm(entryId: UUID)
        case append
        case skip
    }

    func action(for message: Message2) -> Action {
        switch message {
        case .user(let u):
            if let r = u.toolResultBlock, let id = r.toolUseId {
                return .merge(toolUseId: id, result: r)
            }
            if u.isVisible, let entryId = matchQueuedEntry(for: u) {
                return .confirm(entryId: entryId)
            }
            return u.isVisible ? .append : .skip
        case .assistant(let a):
            return a.isVisible ? .append : .skip
        default:
            return .skip
        }
    }

    /// 在 `messages` 里找 uuid 和该 user echo 一致、且仍 `.queued` 的 entry。
    /// CLI 通过 `--replay-user-messages` 原样回显我们发送时塞的 uuid，因此此处
    /// 按 entry.id ↔ echo.uuid 精确配对，不做文本启发式。
    func matchQueuedEntry(for echo: Message2User) -> UUID? {
        guard let raw = echo.uuid,
              let echoId = UUID(uuidString: raw) else { return nil }
        return messages.first { entry in
            entry.id == echoId && entry.delivery == .queued
        }?.id
    }
}

// MARK: - Timeline writes

private extension SessionHandle2 {

    func appendToTimeline(_ message: Message2, mode: ReceiveMode) {
        messages.append(MessageEntry(
            id: UUID(),
            message: message,
            delivery: nil,
            toolResults: [:]
        ))
        if mode == .live, !isFocused { hasUnread = true }
    }

    func attachToolResult(_ result: ItemToolResult, to toolUseId: String) {
        guard let idx = messages.lastIndex(where: { $0.owns(toolUseId: toolUseId) }) else { return }
        messages[idx].toolResults[toolUseId] = result
    }

    /// CLI 开始处理一条先前 `send()` 的消息：原位更新 delivery，并把 status
    /// 推进到 `.responding`（仅 live）。用本地 entry 继续展示，不重复 append。
    func confirmQueuedEntry(id: UUID, mode: ReceiveMode) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].delivery = .confirmed
        if mode == .live, status == .idle {
            status = .responding
        }
    }
}

// MARK: - Effect application

private extension SessionHandle2 {

    func noteUsage(_ usage: MessageUsage?) {
        guard let usage else { return }
        contextUsedTokens = (usage.inputTokens ?? 0)
            + (usage.cacheCreationInputTokens ?? 0)
            + (usage.cacheReadInputTokens ?? 0)
    }

    func finishTurn(with result: Message2Result, mode: ReceiveMode) {
        if let window = result.contextWindow {
            contextWindowTokens = window
        }
        if mode == .live, case .responding = status {
            status = .idle
        }
    }

    func adopt(_ info: Init, mode: ReceiveMode) {
        if let c = info.cwd { cwd = c }
        if let raw = info.permissionMode, let mapped = PermissionMode(rawValue: raw) {
            permissionMode = mapped
        }
        if let cmds = info.slashCommands {
            slashCommands = cmds.map { SlashCommand(name: $0, description: nil) }
        }
        if mode == .live, case .starting = status {
            status = .idle
        }
    }
}

// MARK: - Message introspection

private extension Message2User {

    /// 本消息是否作为独立 entry 进 timeline。
    /// 剔除子 agent、synthetic、compact summary、transcript-only、空文本。
    var isVisible: Bool {
        guard parentToolUseId == nil,
              isSynthetic != true,
              isCompactSummary != true,
              isVisibleInTranscriptOnly != true
        else { return false }
        return hasVisibleText
    }

    var hasVisibleText: Bool {
        switch message?.content {
        case .string(let s)?:
            return !s.isEmpty
        case .array(let items)?:
            return items.contains {
                if case .text(let t) = $0 { return !(t.text?.isEmpty ?? true) }
                return false
            }
        default:
            return false
        }
    }

    /// 第一个 tool_result 块（通常每条 user 消息只带一个）。
    var toolResultBlock: ItemToolResult? {
        guard case .array(let items) = message?.content else { return nil }
        for item in items {
            if case .toolResult(let r) = item { return r }
        }
        return nil
    }
}

private extension Message2Assistant {

    /// 是否有可见内容（text 或 tool_use）。thinking-only / subagent 视为不可见。
    var isVisible: Bool {
        guard parentToolUseId == nil, let blocks = message?.content else { return false }
        return blocks.contains { block in
            switch block {
            case .text(let t): return !(t.text?.isEmpty ?? true)
            case .toolUse: return true
            default: return false
            }
        }
    }
}

private extension Message2Result {

    /// 从 modelUsage 取最大的 contextWindow。success / errorDuringExecution 共用。
    var contextWindow: Int? {
        let usage: [String: ModelUsageValue]?
        switch self {
        case .success(let s): usage = s.modelUsage
        case .errorDuringExecution(let e): usage = e.modelUsage
        case .unknown: usage = nil
        }
        return usage?.values.compactMap(\.contextWindow).max()
    }
}

private extension MessageEntry {

    /// 本 entry 是否为发起该 tool_use 的 assistant 消息。
    func owns(toolUseId: String) -> Bool {
        guard case .assistant(let a) = message,
              let blocks = a.message?.content else { return false }
        return blocks.contains { block in
            guard case .toolUse(let t) = block else { return false }
            return t.id == toolUseId
        }
    }
}
