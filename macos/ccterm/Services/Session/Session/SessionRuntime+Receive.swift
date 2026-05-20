import AgentSDK
import Foundation

// MARK: - ReceiveMode

extension SessionRuntime {

    /// live = real-time CLI push; replay = JSONL history playback.
    /// Only difference: replay does not advance lifecycle and does not set hasUnread.
    enum ReceiveMode { case live, replay }
}

// MARK: - receive

extension SessionRuntime {

    /// Single ingest entry point. Consumes one Message2 and updates the handle:
    /// - Synchronous side effects (usage, contextWindow, cwd, slashCommands, permissionMode, lifecycle)
    /// - user echo whose uuid matches a local `.queued` entry → flip to `.confirmed` and
    ///   replace payload from `.localUser` with `.remote(echo)`, advance status
    /// - tool_result merged in place into the matching assistant single (may live inside a group)
    /// - other visible messages are appended to the timeline per the "groupable" rule
    ///
    /// live and replay share the same path; `mode` only affects lifecycle advancement and hasUnread.
    func receive(_ message: Message2, mode: ReceiveMode = .live) {
        switch message {
        case .assistant(let a):
            noteUsage(a.message?.usage)
            // CLI is producing assistant content → a turn is in progress.
            // Self-heals two real scenarios surfaced by the SDK smoke
            // dump:
            //   1. `.result` arrived earlier than expected (stray /
            //      reordered) but more assistant content follows.
            //   2. CLI spontaneously starts a new turn after a closed
            //      one (e.g. a background bash completes and the CLI
            //      starts its own turn to surface the result).
            // Either way, the spinner should be on while assistant
            // tokens stream in.
            if mode == .live { isRunning = true }
        case .result(let r): finishTurn(with: r, mode: mode)
        case .system(.`init`(let info)):
            // `system.init` arriving *after* the first bootstrap (i.e.
            // `status` is already past `.starting`) means the CLI is
            // re-initialising for a follow-up turn — the dump shows
            // this fires ~one frame before the next `.assistant`. Use
            // it as the earlier wake-up so the spinner relights at the
            // very start of the new turn rather than at first token.
            // The bootstrap init keeps its normal path: `adopt` flips
            // `.starting` → `.idle`; we do NOT touch `isRunning`
            // (`send` either flipped it true already, or no message
            // is in flight and the spinner should stay off).
            if mode == .live, status != .starting {
                isRunning = true
            }
            adopt(info, mode: mode)
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
            appLog(
                .info, "SessionRuntime",
                "[v2-send] receive sid=\(sessionId.prefix(8)) mode=live action=\(actDesc) status=\(status)")
        }
        // Each mutation helper returns the MessagesChange it produced (or nil), so this
        // function can dispatch them uniformly to the bridge via onMessagesChange at the end.
        let change: MessagesChange?
        switch act {
        case .merge(let id, let payload):
            change = attachToolResult(payload, to: id).map(MessagesChange.updated)
        case .confirm(let id, let echo):
            change = confirmQueuedEntry(id: id, echo: echo, mode: mode).map(MessagesChange.updated)
        case .append:
            change = appendToTimeline(message, mode: mode)
        case .skip:
            change = nil
        }

        // For replay, the caller (loadHistory Phase A / Phase B) emits a single
        // `.reset` / `.prepended` at the end of the batch — we do not emit per-message here.
        guard mode == .live else { return }
        if let change { onMessagesChange?(change) }
    }
}

// MARK: - Dispatch

extension SessionRuntime {

    fileprivate enum Action {
        case merge(toolUseId: String, payload: ToolResultPayload)
        /// Local `.queued` entry matched by CLI echo (by uuid); flip to `.confirmed` and
        /// replace payload from `.localUser` with `.remote(echo)`.
        case confirm(entryId: UUID, echo: Message2)
        case append
        case skip
    }

    fileprivate func action(for message: Message2) -> Action {
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

    /// Find an entry in `messages` whose uuid matches this user echo and is still `.queued`.
    /// The CLI echoes back the uuid we sent verbatim via `--replay-user-messages`, so we
    /// pair exactly on entry.id ↔ echo.uuid — no text-based heuristics.
    fileprivate func matchQueuedEntry(for echo: Message2User) -> UUID? {
        guard let raw = echo.uuid,
            let echoId = UUID(uuidString: raw)
        else {
            appLog(
                .info, "SessionRuntime",
                "[v2-send] matchQueued no-uuid echo.uuid=\(echo.uuid ?? "(nil)")")
            return nil
        }
        let hit = messages.first { entry in
            entry.id == echoId && entry.delivery == .queued
        }?.id
        if hit == nil {
            // List all queued user entry ids to see if there are none, or if the uuid simply doesn't match.
            let queued = messages.compactMap { entry -> String? in
                guard case .single(let s) = entry,
                    case .localUser = s.payload,
                    s.delivery == .queued
                else { return nil }
                return s.id.uuidString.prefix(8) + ""
            }
            appLog(
                .warning, "SessionRuntime",
                "[v2-send] matchQueued MISS echoUuid=\(raw.prefix(8)) queued=\(queued)")
        }
        return hit
    }
}

// MARK: - Timeline writes

extension SessionRuntime {

    fileprivate func appendToTimeline(_ message: Message2, mode: ReceiveMode) -> MessagesChange {
        let single = SingleEntry(id: UUID(), payload: .remote(message), delivery: nil, toolResults: [:])

        // change differs in two cases:
        // - appending to an existing group's items → the group entry's contents changed → `.updated`
        // - creating a new group / appending a .single → timeline gained an entry → `.appended`
        let change: MessagesChange
        if message.isGroupableAssistant {
            if case .group(var g) = messages.last {
                g.items.append(single)
                messages[messages.count - 1] = .group(g)
                change = .updated(messages[messages.count - 1])
            } else {
                messages.append(.group(GroupEntry(id: UUID(), items: [single])))
                change = .appended(messages.last!)
            }
        } else {
            messages.append(.single(single))
            change = .appended(messages.last!)
        }

        if mode == .live, !isFocused { hasUnread = true }
        return change
    }

    /// Attach tool_result to the assistant single that issued the matching tool_use.
    /// Reverse scan: match a top-level `.single` directly; for `.group`, descend into items.
    /// Returns the mutated entry (`.single` or `.group`) so the caller can wrap it in
    /// `MessagesChange.updated`; if tool_use_id has no matching entry → nil
    /// (older CLI versions occasionally emit tool_result without an anchor).
    fileprivate func attachToolResult(_ payload: ToolResultPayload, to toolUseId: String) -> MessageEntry? {
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

    /// CLI began processing a previously `send()`-ed message: swap payload from `.localUser`
    /// to `.remote(echo)`, flip delivery to `.confirmed`, and advance status to `.responding`
    /// (live only). Reuse the local entry for display — do not append a duplicate. Returns
    /// the mutated entry so the caller can wrap it in `MessagesChange.updated`; id miss / non-single → nil.
    fileprivate func confirmQueuedEntry(id: UUID, echo: Message2, mode: ReceiveMode) -> MessageEntry? {
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

extension SessionRuntime {

    fileprivate func noteUsage(_ usage: MessageUsage?) {
        guard let usage else { return }
        contextUsedTokens =
            (usage.inputTokens ?? 0)
            + (usage.cacheCreationInputTokens ?? 0)
            + (usage.cacheReadInputTokens ?? 0)
    }

    fileprivate func finishTurn(with result: Message2Result, mode: ReceiveMode) {
        if let window = result.contextWindow {
            contextWindowTokens = window
        }
        if mode == .live {
            appLog(
                .info, "SessionRuntime",
                "[v2-send] finishTurn sid=\(sessionId.prefix(8)) status-before=\(status) isRunning-before=\(isRunning)"
            )
            // `.result` is the CLI's only authoritative "turn ended"
            // signal — flip the spinner off. If the CLI then starts
            // another turn on its own (background-bash completion,
            // continuation, …), the next `.assistant` in `receive`
            // flips us back true.
            isRunning = false
        }
        if mode == .live, case .responding = status {
            status = .idle
        }
    }

    fileprivate func adopt(_ info: Init, mode: ReceiveMode) {
        if let c = info.cwd { cwd = c }
        if let raw = info.permissionMode, let mapped = PermissionMode(rawValue: raw) {
            permissionMode = mapped
        }
        if let cmds = info.slashCommands {
            slashCommands = cmds.map { SlashCommand(name: $0, description: nil) }
        }
        if mode == .live {
            appLog(
                .info, "SessionRuntime",
                "[v2-send] adopt-init sid=\(sessionId.prefix(8)) status-before=\(status) cwd=\(info.cwd ?? "(nil)")")
        }
        if mode == .live, case .starting = status {
            status = .idle
        }
    }
}

// MARK: - Message introspection

extension Message2User {

    /// Whether this message enters the timeline as its own entry.
    /// Filters out sub-agents, synthetic, compact summary, transcript-only, and empty text.
    fileprivate var isVisible: Bool {
        guard parentToolUseId == nil,
            isSynthetic != true,
            isCompactSummary != true,
            isVisibleInTranscriptOnly != true
        else { return false }
        return hasVisibleText
    }

    fileprivate var hasVisibleText: Bool {
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

    /// The first tool_result block (each user message typically carries only one).
    fileprivate var toolResultBlock: ItemToolResult? {
        guard case .array(let items) = message?.content else { return nil }
        for item in items {
            if case .toolResult(let r) = item { return r }
        }
        return nil
    }
}

extension Message2Assistant {

    /// Has any visible content (text or tool_use). thinking-only / subagent is treated as invisible.
    fileprivate var isVisible: Bool {
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

extension Message2 {

    /// "Groupable": an assistant message whose non-empty content blocks are all tool_use (any kind).
    /// Mixed text / thinking still goes through `.single` and is rendered by `AssistantMarkdownComponent`.
    fileprivate var isGroupableAssistant: Bool {
        guard case .assistant(let a) = self,
            let blocks = a.message?.content,
            !blocks.isEmpty
        else { return false }
        for block in blocks {
            guard case .toolUse = block else { return false }
        }
        return true
    }
}

extension Message2Result {

    /// Take the max contextWindow from modelUsage. Shared by success / errorDuringExecution.
    fileprivate var contextWindow: Int? {
        let usage: [String: ModelUsageValue]?
        switch self {
        case .success(let s): usage = s.modelUsage
        case .errorDuringExecution(let e): usage = e.modelUsage
        case .unknown: usage = nil
        }
        return usage?.values.compactMap(\.contextWindow).max()
    }
}
