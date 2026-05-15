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
    /// - user echo 带 uuid 命中本地 `.queued` entry → 切 `.confirmed` 并把 payload
    ///   从 `.localUser` 替换为 `.remote(echo)`，推进 status
    /// - tool_result 原位合并到对应 assistant single（可能位于 group 内部）
    /// - 其它可见消息按「可分组」规则 append 到 timeline
    ///
    /// live 与 replay 走同一路径；`mode` 仅影响 lifecycle 推进与 hasUnread 触发。
    func receive(_ message: Message2, mode: ReceiveMode = .live) {
        switch message {
        case .assistant(let a): noteUsage(a.message?.usage)
        case .result(let r): finishTurn(with: r, mode: mode)
        case .system(.`init`(let info)): adopt(info, mode: mode)
        default: break
        }

        let act = action(for: message)
        if mode == .live {
            let actDesc: String
            switch act {
            case .merge(let id, _): actDesc = "merge(\(id.prefix(8)))"
            case .confirm(let id, _): actDesc = "confirm(\(id.uuidString.prefix(8)))"
            case .append: actDesc = "append"
            case .skip: actDesc = "skip"
            }
            appLog(.info, "SessionHandle2",
                "[v2-send] receive sid=\(sessionId.prefix(8)) mode=live action=\(actDesc) status=\(status)")
        }
        // 每个 mutation helper 返回它产出的 TimelineMutation(或 nil),让本
        // 函数最后统一 emit sink。这样 sink 触发点和 emitSnapshot 在同一
        // 位置,future maintainer 改任一时都能看见对应路径。
        let mutation: TimelineMutation?
        switch act {
        case .merge(let id, let payload):
            mutation = attachToolResult(payload, to: id).map(TimelineMutation.mutated)
        case .confirm(let id, let echo):
            mutation = confirmQueuedEntry(id: id, echo: echo, mode: mode).map(TimelineMutation.mutated)
        case .append:
            mutation = appendToTimeline(message, mode: mode)
        case .skip:
            mutation = nil
        }

        // replay 批量 ingest 由调用方（loadHistory Phase A / Phase B）一次性
        // emit `.initialPaint` / `.prependHistory`——此处不发 per-message。
        guard mode == .live else { return }
        switch act {
        case .append: emitSnapshot(.liveAppend)
        case .merge, .confirm: emitSnapshot(.update)
        case .skip: break
        }
        if let mutation { onTimelineMutation?(mutation) }
    }
}

// MARK: - Dispatch

private extension SessionHandle2 {

    enum Action {
        case merge(toolUseId: String, payload: ToolResultPayload)
        /// 本地 `.queued` entry 命中 CLI echo（按 uuid 匹配），切 `.confirmed` 且
        /// payload 从 `.localUser` 替换为 `.remote(echo)`。
        case confirm(entryId: UUID, echo: Message2)
        case append
        case skip
    }

    func action(for message: Message2) -> Action {
        switch message {
        case .user(let u):
            if let r = u.toolResultBlock, let id = r.toolUseId {
                let payload = ToolResultPayload(item: r, typed: u.toolUseResult)
                return .merge(toolUseId: id, payload: payload)
            }
            if u.isVisible, let entryId = matchQueuedEntry(for: u) {
                return .confirm(entryId: entryId, echo: message)
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
              let echoId = UUID(uuidString: raw) else {
            appLog(.info, "SessionHandle2",
                "[v2-send] matchQueued no-uuid echo.uuid=\(echo.uuid ?? "(nil)")")
            return nil
        }
        let hit = messages.first { entry in
            entry.id == echoId && entry.delivery == .queued
        }?.id
        if hit == nil {
            // 列出所有 queued user entry id,看是否压根没有,或 uuid 对不上
            let queued = messages.compactMap { entry -> String? in
                guard case .single(let s) = entry,
                      case .localUser = s.payload,
                      s.delivery == .queued else { return nil }
                return s.id.uuidString.prefix(8) + ""
            }
            appLog(.warning, "SessionHandle2",
                "[v2-send] matchQueued MISS echoUuid=\(raw.prefix(8)) queued=\(queued)")
        }
        return hit
    }
}

// MARK: - Timeline writes

private extension SessionHandle2 {

    func appendToTimeline(_ message: Message2, mode: ReceiveMode) -> TimelineMutation {
        let single = SingleEntry(id: UUID(), payload: .remote(message), delivery: nil, toolResults: [:])

        // mutation 在两种情况下不同:
        // - 追加到既存 group 的 items → group entry 本体改了内容 → `.mutated`
        // - 新建 group / append .single → 时间线多了一条 entry → `.appended`
        let mutation: TimelineMutation
        if message.isGroupableAssistant {
            if case .group(var g) = messages.last {
                g.items.append(single)
                messages[messages.count - 1] = .group(g)
                mutation = .mutated(messages[messages.count - 1])
            } else {
                messages.append(.group(GroupEntry(id: UUID(), items: [single])))
                mutation = .appended(messages.last!)
            }
        } else {
            messages.append(.single(single))
            mutation = .appended(messages.last!)
        }

        if mode == .live, !isFocused { hasUnread = true }
        return mutation
    }

    /// 把 tool_result 挂到发起该 tool_use 的 assistant single 上。
    /// 倒序搜索：匹配顶层 `.single` 直接挂；匹配 `.group` 时下探 items。
    /// 返回被改动的 entry(`.single` 或 `.group`),由 caller 转成
    /// `TimelineMutation.mutated`;tool_use_id 找不到对应 entry → 返回 nil
    /// (老 CLI 偶发 tool_result 找不到锚点)。
    func attachToolResult(_ payload: ToolResultPayload, to toolUseId: String) -> MessageEntry? {
        for i in messages.indices.reversed() {
            switch messages[i] {
            case .single(var e):
                if e.ownsToolUse(toolUseId) {
                    e.toolResults[toolUseId] = payload
                    messages[i] = .single(e)
                    return messages[i]
                }
            case .group(var g):
                if let j = g.items.lastIndex(where: { $0.ownsToolUse(toolUseId) }) {
                    g.items[j].toolResults[toolUseId] = payload
                    messages[i] = .group(g)
                    return messages[i]
                }
            }
        }
        return nil
    }

    /// CLI 开始处理一条先前 `send()` 的消息：把 payload 从 `.localUser` 换成
    /// `.remote(echo)`、delivery 切 `.confirmed`，并把 status 推进到 `.responding`
    /// （仅 live）。用本地 entry 继续展示，不重复 append。返回被改动的 entry,
    /// 给 caller 转成 `TimelineMutation.mutated`;id 不命中 / 非 single → nil。
    func confirmQueuedEntry(id: UUID, echo: Message2, mode: ReceiveMode) -> MessageEntry? {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return nil }
        guard case .single(var single) = messages[idx] else { return nil }
        single.payload = .remote(echo)
        single.delivery = .confirmed
        messages[idx] = .single(single)
        if mode == .live, status == .idle {
            status = .responding
        }
        return messages[idx]
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
        if mode == .live {
            appLog(.info, "SessionHandle2",
                "[v2-send] finishTurn sid=\(sessionId.prefix(8)) status-before=\(status) pendingTurnCount=\(pendingTurnCount)")
            // turn 结束 -- 每条 .result 对应一条之前 send() 入口 +1 的 turn。
            // clamp 到 0,replay 模式 / 异常多发不会走负。
            pendingTurnCount = max(0, pendingTurnCount - 1)
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
        if mode == .live {
            appLog(.info, "SessionHandle2",
                "[v2-send] adopt-init sid=\(sessionId.prefix(8)) status-before=\(status) cwd=\(info.cwd ?? "(nil)")")
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

private extension Message2 {

    /// 「可分组」：assistant 消息，其所有非空 content block 均为 tool_use（任意 kind）。
    /// 混合 text / thinking 仍走 `.single`，由 `AssistantMarkdownComponent` 渲染。
    var isGroupableAssistant: Bool {
        guard case .assistant(let a) = self,
              let blocks = a.message?.content,
              !blocks.isEmpty else { return false }
        for block in blocks {
            guard case .toolUse = block else { return false }
        }
        return true
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
