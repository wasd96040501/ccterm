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
            // Capture TaskCreate / TaskUpdate tool_use inputs so the
            // pairing user.tool_result can materialize / patch the
            // entry in `todos`. Runs in both live and replay so the
            // popover list is correct after a JSONL reload.
            captureTodoToolUses(in: a)
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
            // Flush queued local-user entries now that CLI has signalled
            // "turn starting". `system.init` arrives ~5-20 ms after the
            // matching `sendMessage`, while the `--replay-user-messages`
            // echo doesn't land until ~2 s later (in lockstep with the
            // first assistant token). Using init as the confirm trigger
            // shaves ~2 s off the queued visual without losing the FIFO
            // semantics — CLI bundles every send that's in its stdin
            // buffer at turn-start into one turn, so flushing every
            // currently-queued entry on init matches CLI behaviour. See
            // `AgentSDK/Sources/QueueTimingSmoke` for the measurements.
            if mode == .live {
                flushQueuedOnInit()
            }
        case .system(.status(let s)):
            // CLI broadcasts a `system.status` whenever the
            // session-side permission mode changes. Three triggers
            // observed in PermissionModeProbe:
            //   1. EnterPlanMode runs (no permission_request) → CLI
            //      pushes `permissionMode=plan`.
            //   2. User responds to a permission_request with
            //      allowAlways + `setMode` suggestion (Edit/Write
            //      default to `setMode=acceptEdits`) → CLI pushes the
            //      new mode after applying the update.
            //   3. The CLI silently rejects a requested mode (e.g.
            //      `bypassPermissions` when --allow-dangerously-skip is
            //      off, or `plan` from ExitPlanMode which must leave
            //      plan mode) → CLI pushes the corrected mode
            //      (typically `default`).
            // Case 3 is why we must trust the CLI, not the optimistic
            // local write in setPermissionMode: this branch is the
            // self-heal that pulls UI state back to reality.
            adoptPermissionMode(s.permissionMode)
        case .system(.taskStarted(let started)) where mode == .live:
            handleTaskStarted(started)
        case .system(.taskNotification(let notif)) where mode == .live:
            handleTaskNotification(notif)
        case .system(.taskUpdated(let updated)) where mode == .live:
            handleTaskUpdated(updated)
        case .user(let u) where u.toolResultBlock?.toolUseId != nil:
            // Capture backgroundTaskId → outputFile mapping when the bash
            // tool's tool_result lands. system.task_started doesn't carry
            // the output path (it's allocated lazily when the CLI writes
            // its first byte to the spool file), so this is the earliest
            // reliable point to record where to tail from.
            if mode == .live { rememberOutputFileFromBashResult(u) }
            // Fold any TaskCreate / TaskUpdate result into `todos`. Runs
            // for both live and replay so the popover state survives a
            // JSONL reload.
            applyTodoToolResult(u)
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
        /// Local entry matched by CLI echo (by uuid); flip delivery to
        /// `.confirmed` and swap payload to `.remote(echo)`. Idempotent
        /// when the entry is already `.confirmed` (CLI replay during
        /// interrupt).
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
            if u.isVisible, let entryId = matchExistingEntry(for: u) {
                return .confirm(entryId: entryId, echo: message)
            }
            return u.isVisible ? .append : .skip
        case .assistant(let a):
            return a.isVisible ? .append : .skip
        default:
            return .skip
        }
    }

    /// Find an entry in `messages` whose uuid matches this user echo,
    /// regardless of delivery state. The CLI echoes back the uuid we
    /// sent verbatim under `--replay-user-messages`, so a match means
    /// "we already represent this message" — convert / no-op rather
    /// than append a duplicate. Three real scenarios hit non-`.queued`
    /// states:
    ///
    /// - `.failed`: user clicked interrupt while the entry was still
    ///   `.queued`; `failQueuedEntries` flipped it; CLI's echo lands
    ///   afterward. We restore `.confirmed` so the bubble doesn't
    ///   read as a failed delivery after the CLI actually accepted it.
    /// - `.confirmed`: CLI replayed an already-confirmed user message
    ///   (observed around interrupt boundaries). Drop it — we'd
    ///   otherwise show two identical bubbles.
    fileprivate func matchExistingEntry(for echo: Message2User) -> UUID? {
        guard let raw = echo.uuid,
            let echoId = UUID(uuidString: raw)
        else {
            appLog(
                .info, "SessionRuntime",
                "[v2-send] matchExisting no-uuid echo.uuid=\(echo.uuid ?? "(nil)")")
            return nil
        }
        let hit = messages.first { entry in
            guard entry.id == echoId else { return false }
            guard case .single(let s) = entry else { return false }
            switch s.payload {
            case .localUser: return true
            case .remote(let m):
                if case .user = m { return true }
                return false
            }
        }?.id
        if hit == nil {
            let queued = messages.compactMap { entry -> String? in
                guard case .single(let s) = entry,
                    case .localUser = s.payload,
                    s.delivery == .queued
                else { return nil }
                return s.id.uuidString.prefix(8) + ""
            }
            appLog(
                .warning, "SessionRuntime",
                "[v2-send] matchExisting MISS echoUuid=\(raw.prefix(8)) queued=\(queued)")
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

    /// CLI began processing a previously `send()`-ed message, OR is
    /// replaying an already-confirmed one (observed around interrupt).
    /// Swap payload to `.remote(echo)`, flip delivery to `.confirmed`,
    /// and — only on the `.queued` → `.confirmed` edge in live mode —
    /// advance status to `.responding`. Reuse the local entry; never
    /// append a duplicate.
    ///
    /// Two prior states are both fine to land on:
    ///   1. `.localUser` + `.queued`  — echo arrived before init flush
    ///      (rare; happens when init is skipped or delayed). Flip
    ///      delivery and swap payload.
    ///   2. `.localUser` + `.confirmed` — `flushQueuedOnInit` already
    ///      ran. Delivery is already correct; still swap the payload
    ///      so the entry adopts the CLI-canonical form. Returns the
    ///      updated entry so the bridge re-renders the bubble.
    ///
    /// Re-confirm of an already-`.remote` entry (CLI replay during
    /// interrupt) returns nil — the entry has already adopted the
    /// CLI form once; don't thrash payload or status.
    fileprivate func confirmQueuedEntry(id: UUID, echo: Message2, mode: ReceiveMode) -> MessageEntry? {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return nil }
        guard case .single(var single) = messages[idx] else { return nil }
        if case .remote = single.payload {
            return nil
        }
        let wasQueued = single.delivery == .queued
        single.payload = .remote(echo)
        single.delivery = .confirmed
        messages[idx] = .single(single)
        if mode == .live, wasQueued, status == .idle {
            status = .responding
        }
        return messages[idx]
    }

    /// Walk `messages`, flip every locally-queued user entry to
    /// `.confirmed`, and emit one `MessagesChange.updated` per flipped
    /// entry. Payload stays as `.localUser` — the canonical-form swap
    /// to `.remote(echo)` still happens later when the echo lands
    /// (`confirmQueuedEntry`). Only the *delivery* flag — and the
    /// status transition `.idle` → `.responding` — moves here.
    ///
    /// Called from the `system.init` arm of `receive`. CLI buffers
    /// every send that's sitting in its stdin queue at turn-start into
    /// a single follow-up turn, so flushing every currently-queued
    /// entry on each init is correct in both single-send and
    /// burst-send scenarios. The narrow race where a `.queued` entry
    /// arrives *between* init-fire and CLI's actual stdin read would
    /// land here optimistically; in practice the window is sub-ms and
    /// echoes still arrive later to do the payload swap.
    fileprivate func flushQueuedOnInit() {
        var anyFlushed = false
        for i in messages.indices {
            guard case .single(var single) = messages[i] else { continue }
            guard case .localUser = single.payload else { continue }
            guard single.delivery == .queued else { continue }
            single.delivery = .confirmed
            messages[i] = .single(single)
            anyFlushed = true
            onMessagesChange?(.updated(messages[i]))
        }
        if anyFlushed, status == .idle {
            status = .responding
        }
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
            // Notify the renderer so any tool surface still in
            // `.running` (no matching `tool_result` arrived before
            // turn-close) flips to `.completed`. Fires on every live
            // turn close, not just `.responding → .idle`.
            onTurnFinishedLive?()
        }
        if mode == .live, case .responding = status {
            status = .idle
            // The `.responding → .idle` edge is the "user-initiated turn
            // just finished" signal. CLI-driven follow-ups (background
            // bash continuations etc.) flip `isRunning` but never enter
            // `.responding`, so they don't trip a duplicate notification.
            let displayTitle =
                title.isEmpty ? String(localized: "Untitled") : title
            let body = snapshotLastAssistantText() ?? ""
            onTurnEnded?(
                TurnEndedNotice(
                    sessionId: sessionId,
                    title: displayTitle,
                    body: body
                ))
        }
    }

    /// Reverse-scan the timeline for the most recent assistant message
    /// carrying visible text (skipping `.group` entries — those are pure
    /// tool_use runs with no text — and skipping single assistants that
    /// only carry thinking or tool_use blocks). Returns the concatenated
    /// text of every `.text` block on that single, separated by blank
    /// lines and trimmed.
    fileprivate func snapshotLastAssistantText() -> String? {
        for entry in messages.reversed() {
            guard case .single(let s) = entry,
                case .assistant(let a) = s.remoteMessage,
                let blocks = a.message?.content
            else { continue }
            let parts: [String] = blocks.compactMap { block in
                if case .text(let t) = block,
                    let txt = t.text,
                    !txt.isEmpty
                {
                    return txt
                }
                return nil
            }
            if !parts.isEmpty {
                return parts.joined(separator: "\n\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    /// Receive-side permission mode sync. Idempotent: same mode is a
    /// no-op (no observable churn, no DB write). DB write skipped for
    /// pre-record sessions (first bootstrap before persistence). Does
    /// **not** call `setPermissionMode` — that path issues a
    /// `set_permission_mode` RPC to the CLI, which would loop back as
    /// another `system.status`.
    fileprivate func adoptPermissionMode(_ raw: String?) {
        guard let raw,
            let mapped = PermissionMode(rawValue: raw),
            mapped != permissionMode
        else { return }
        permissionMode = mapped
        if repository.find(sessionId) != nil {
            repository.updateExtra(
                sessionId, with: SessionExtraUpdate(permissionMode: raw))
        }
    }

    fileprivate func adopt(_ info: Init, mode: ReceiveMode) {
        if let c = info.cwd { cwd = c }
        adoptPermissionMode(info.permissionMode)
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
    ///
    /// Module-internal (not `fileprivate`) so the pure `ReverseEntryBuilder`
    /// reuses the exact same visibility rule the live `receive` path uses —
    /// the single source of truth `TranscriptReverseBuilderTests.A6` pins.
    var isVisible: Bool {
        guard parentToolUseId == nil,
            isSynthetic != true,
            isCompactSummary != true,
            isVisibleInTranscriptOnly != true,
            // The CLI marks any user envelope whose turn was triggered
            // by a background task notification with
            // `origin.kind == "task-notification"`. Newer CLI builds may
            // surface that as its own synthetic user record (the
            // task-notification turn currently emits only a system.init
            // + assistant block, but the CLI has shifted that contract
            // before). Treat such envelopes as control signals so the
            // tasks popover is the sole surface for completion-related
            // chatter.
            origin?.kind != "task-notification",
            // Content-prefix fallback: older CLI builds (observed in
            // smoke dumps as early as 2026-02) injected the synthetic
            // task-notification user turn without the `origin` field at
            // all. The `<task-notification>` XML envelope itself has
            // been stable across every CLI version we have on file, so
            // a string body that starts with it is a CLI control signal
            // regardless of envelope metadata.
            !startsWithTaskNotificationEnvelope
        else { return false }
        return hasVisibleText
    }

    /// Whether `message.content` begins with the `<task-notification>`
    /// XML envelope. Backstop for legacy CLI builds that don't set
    /// `origin.kind`. Checks both string-shaped content and the first
    /// text block of array-shaped content; non-text content shapes
    /// (e.g. tool_result, image) return false.
    fileprivate var startsWithTaskNotificationEnvelope: Bool {
        let marker = "<task-notification>"
        switch message?.content {
        case .string(let s)?:
            return s.hasPrefix(marker)
        case .array(let items)?:
            for item in items {
                if case .text(let t) = item, let txt = t.text {
                    return txt.hasPrefix(marker)
                }
            }
            return false
        default:
            return false
        }
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
    /// Module-internal so `ReverseEntryBuilder` classifies tool_result the same
    /// way `receive`'s `action(for:)` does.
    var toolResultBlock: ItemToolResult? {
        guard case .array(let items) = message?.content else { return nil }
        for item in items {
            if case .toolResult(let r) = item { return r }
        }
        return nil
    }
}

extension Message2Assistant {

    /// Has any visible content (text or tool_use). thinking-only / subagent is treated as invisible.
    /// Module-internal so `ReverseEntryBuilder` shares the live visibility rule.
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

extension Message2 {

    /// "Groupable": an assistant message whose non-empty content blocks are all tool_use (any kind).
    /// Mixed text / thinking still goes through `.single` and is rendered by `AssistantMarkdownComponent`.
    /// Module-internal so `ReverseEntryBuilder` applies the same grouping rule as `appendToTimeline`.
    var isGroupableAssistant: Bool {
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
