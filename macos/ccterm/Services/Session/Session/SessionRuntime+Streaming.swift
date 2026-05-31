import AgentSDK
import Foundation

// MARK: - Partial-message stream consumption + typewriter reveal
//
// The CLI is launched with `--include-partial-messages` (see
// `SessionConfig.toAgentSDKConfig`), so the SDK delivers SSE-style deltas on
// `Session.onStreamEvent`. `attachCallbacks` hops each event to the main actor
// and funnels it here. We consume only what we render:
//
//   • `text_delta` → live assistant text. Accumulated per message in
//     `StreamingTurnAssembler`, then *revealed one glyph at a time* by a
//     `TypewriterReveal` paced off `frameTicker` — the bursty network chunks
//     are decoupled from a smooth, character-by-character display rate. The
//     revealed prefix is run through `StreamingMarkdownCommit` (holds
//     incomplete code blocks / tables) and surfaced as a *provisional*
//     timeline entry that the finalized `.assistant` envelope reuses in place
//     (see `SessionRuntime+Receive`).
//   • `message_start` / `message_delta` usage → live turn token totals
//     (input + output, cache excluded), shown beside the running pill.
//
// `thinking_delta` / `input_json_delta` are ignored — thinking isn't rendered,
// and tool calls render through the finalized `onMessage` path unchanged.
//
// ### Convergence without a snap
//
// When the head still trails the received text and the finalized `.assistant`
// envelope arrives, the swap to authoritative text is **deferred** (the
// envelope is parked on `TypewriterReveal.pendingFinalize`) until the head
// catches up — so a short message types all the way to its end instead of the
// untyped tail popping in. A new `message_start` arriving first (the common
// text-then-tool turn) snaps the previous message and lets its own envelope
// converge normally. See `replaceAssistantEntry` in `SessionRuntime+Receive`.

extension SessionRuntime {

    /// Drop all per-turn streaming state. Called from `enqueueAndSend` when a
    /// new user turn starts.
    func resetStreamingTurn() {
        // Settle any leftover reveal (rare at new-turn time) before tearing
        // the ticker down, so a half-typed preview from the prior turn lands
        // its full text rather than freezing.
        completeActiveReveal()
        stopTypewriter()
        activeReveal = nil
        streamingAssembler.reset()
        streamingPreviewEntryIds = [:]
        // Anchor the running pill's elapsed clock at the turn start, then push
        // the zeroed usage — the sink site re-reads `turnStartedAt` alongside
        // it, so the clock restarts in lockstep with the counter.
        turnStartedAt = Date()
        publishTurnUsage(.zero)
    }

    /// Snap and stop the typewriter on an abnormal turn end (manual stop,
    /// launch failure, process exit). Self-stops on its own when the reveal
    /// drains, but settling immediately keeps the visible text whole.
    func finalizeStreamingOnTermination() {
        completeActiveReveal()
        stopTypewriter()
        activeReveal = nil
    }

    /// Single funnel for `turnUsage` writes: update the stored value and push it
    /// to the AppKit pill imperatively (no observation). See `turnUsage`.
    func publishTurnUsage(_ usage: TurnTokenUsage) {
        turnUsage = usage
        onTurnUsageChange?(usage)
    }

    /// Fold the CLI's cumulative thinking-token estimate
    /// (`system.thinking_tokens.estimated_tokens`) into the running output total
    /// so the `↓` counter climbs during the redacted thinking phase. Called from
    /// `receive`'s `.system(.thinkingTokens)` arm. The authoritative
    /// `message_delta` total supersedes it later (see `StreamingTurnAssembler`).
    func foldThinkingEstimate(cumulativeEstimate: Int) {
        guard streamingAssembler.recordThinkingEstimate(cumulativeEstimate: cumulativeEstimate)
        else { return }
        publishTurnUsage(streamingAssembler.turnUsage)
    }

    /// Fold one typed stream event (already hopped to the main actor) into the
    /// turn state. Text feeds the typewriter reveal synchronously (so a delta
    /// that lands just before a `message_start` is never lost to the
    /// assembler's per-message reset); usage rides the coalesced flush.
    func consumeStreamEvent(_ event: Message2StreamEvent) {
        let outcome = streamingAssembler.consume(event)

        // A new assistant message began — snap the previous reveal (keeping its
        // preview-entry mapping so its own envelope still converges) and open a
        // fresh reveal for the new id.
        if outcome.startedMessage, let id = streamingAssembler.currentMessageId {
            beginReveal(messageId: id)
        }

        // Capture the latest accumulated text onto the active reveal *now*, not
        // on the deferred flush: the next event may be a `message_start` that
        // resets the assembler, which would otherwise drop this delta's text.
        if outcome.textChanged, let id = streamingAssembler.currentMessageId,
            activeReveal?.messageId == id
        {
            activeReveal?.target = streamingAssembler.currentText
            startTypewriterIfNeeded()
        }

        // Usage-only churn (message_start input tokens, message_delta output
        // total) stays coalesced — one pill-counter publish per runloop tick.
        if outcome.usageChanged {
            scheduleStreamingFlush()
        }
    }

    /// Reconcile the assembler's per-message usage against a finalized
    /// `.assistant` envelope's authoritative figures, then refresh `turnUsage`.
    /// Called from `receive`'s `.assistant` arm.
    func reconcileFinalUsage(_ assistant: Message2Assistant) {
        guard let id = assistant.message?.id else { return }
        streamingAssembler.recordUsage(
            messageId: id,
            input: assistant.message?.usage?.inputTokens,
            output: assistant.message?.usage?.outputTokens)
        publishTurnUsage(streamingAssembler.turnUsage)
    }

    // MARK: - Coalesced usage flush

    /// Collapse a burst of usage-bearing events into one pill publish per
    /// runloop tick. The scheduled task reads the *latest* assembler usage.
    private func scheduleStreamingFlush() {
        guard !streamingFlushScheduled else { return }
        streamingFlushScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.streamingFlushScheduled = false
            self.publishTurnUsage(self.streamingAssembler.turnUsage)
        }
    }

    // MARK: - Typewriter reveal

    /// Open a reveal for `messageId`, completing the prior one first. The
    /// prior message's `target` is already current (set synchronously on its
    /// last `text_delta`), so completing it here snaps its full text.
    private func beginReveal(messageId: String) {
        if let current = activeReveal, current.messageId != messageId {
            completeActiveReveal()
        }
        if activeReveal?.messageId != messageId {
            activeReveal = TypewriterReveal(messageId: messageId)
        }
    }

    /// Start the frame ticker if there is reveal work pending. Idempotent —
    /// re-armed only on the running → stopped edge.
    private func startTypewriterIfNeeded() {
        guard let reveal = activeReveal, reveal.hasWork, !typewriterRunning else { return }
        typewriterRunning = true
        frameTicker.start { [weak self] dt in
            self?.onTypewriterTick(dt: dt)
        }
        // Paint the first frame synchronously, in the same runloop turn as the
        // delta that started the reveal. The frame timer's first fire is ~16ms
        // out, but a finalized envelope for a short, fast reply can arrive in
        // the same runloop batch — and `action(for:)` finding no preview entry
        // would append a duplicate. Surfacing now creates the provisional entry
        // (and its `streamingPreviewEntryIds` mapping) before any envelope is
        // processed, so convergence always has a preview to land on.
        onTypewriterTick(dt: 1.0 / 60.0)
    }

    private func stopTypewriter() {
        guard typewriterRunning else { return }
        typewriterRunning = false
        frameTicker.stop()
    }

    /// One frame: advance the head, surface the grown prefix, and — once the
    /// head reaches a sealed (finalized) end — settle the authoritative
    /// envelope. Stops the ticker when there is no more work.
    private func onTypewriterTick(dt: Double) {
        guard var reveal = activeReveal else {
            stopTypewriter()
            return
        }
        reveal.advance(dt: dt)
        surface(&reveal)

        if reveal.isCaughtUp, let pending = reveal.pendingFinalize {
            // Head reached the sealed end → swap the provisional preview for
            // the authoritative envelope and retire the reveal.
            activeReveal = nil
            performAssistantSwap(entryId: pending.entryId, message: pending.message)
            stopTypewriter()
            return
        }

        activeReveal = reveal
        if !reveal.hasWork { stopTypewriter() }
    }

    /// Render the currently-revealed prefix through `StreamingMarkdownCommit`
    /// (which still holds an incomplete trailing code block / table) and surface
    /// it as the provisional entry. Skips the re-typeset when the committed
    /// text is unchanged from the last frame.
    private func surface(_ reveal: inout TypewriterReveal) {
        let revealedRaw = String(reveal.target.prefix(reveal.revealedCount))
        let committed = StreamingMarkdownCommit.committedPrefix(of: revealedRaw)
        guard committed != reveal.lastSurfaced else { return }
        reveal.lastSurfaced = committed
        guard !committed.isEmpty else { return }
        applyStreamingPreview(messageId: reveal.messageId, committedText: committed)
    }

    /// Snap the active reveal to its full committed text and either settle a
    /// parked finalize or leave the preview mapping for the envelope to
    /// converge later. Clears `activeReveal`.
    private func completeActiveReveal() {
        guard var reveal = activeReveal else { return }
        let committed = StreamingMarkdownCommit.committedPrefix(of: reveal.target)
        if committed != reveal.lastSurfaced, !committed.isEmpty {
            reveal.lastSurfaced = committed
            applyStreamingPreview(messageId: reveal.messageId, committedText: committed)
        }
        activeReveal = nil
        if let pending = reveal.pendingFinalize {
            performAssistantSwap(entryId: pending.entryId, message: pending.message)
        }
        // Otherwise: leave `streamingPreviewEntryIds[messageId]` so the
        // finalized envelope converges via the normal immediate path.
    }

    // MARK: - Deferred finalize (called from receive)

    /// Whether the finalized envelope for `messageId` should wait for the
    /// typewriter to catch up before swapping. True only while that message is
    /// the active reveal and its head still trails the text.
    func shouldDeferFinalize(messageId: String) -> Bool {
        guard let reveal = activeReveal, reveal.messageId == messageId else { return false }
        return reveal.hasWork
    }

    /// Park a finalized `.assistant` envelope on the active reveal, sealing the
    /// reveal target to the authoritative text. The typewriter performs the
    /// swap (and emits the `.updated`) once the head reaches the end.
    func scheduleFinalize(entryId: UUID, messageId: String, message: Message2) {
        guard activeReveal?.messageId == messageId else { return }
        // Seal the target to the authoritative text so the head reveals to the
        // true end before swapping. Falls back to the streamed text if the
        // envelope carries none (mixed text + tool message with empty text).
        if let text = Self.joinedAssistantText(message), !text.isEmpty {
            activeReveal?.target = text
        }
        activeReveal?.pendingFinalize = (entryId, message)
        // The stream is done — drop the pacer's playout cushion so the head
        // drains straight to the sealed end instead of trailing by the cushion.
        activeReveal?.seal()
        startTypewriterIfNeeded()
    }
}

// MARK: - Provisional preview entry

extension SessionRuntime {

    /// Surface (or update) the provisional assistant entry for the currently
    /// streaming message. Keyed by `message.id` so the finalized envelope
    /// reuses the same entry id and converges in place.
    fileprivate func applyStreamingPreview(messageId: String, committedText: String) {
        let entryId =
            streamingPreviewEntryIds[messageId]
            ?? StableBlockID.derive("streamAssistant", messageId)
        let synthetic = Self.syntheticAssistantMessage(messageId: messageId, text: committedText)
        let single = SingleEntry(
            id: entryId, payload: .remote(synthetic), delivery: nil, toolResults: [:])

        if let idx = messages.firstIndex(where: { $0.id == entryId }) {
            messages[idx] = .single(single)
            onMessagesChange?(.updated(messages[idx]))
        } else {
            streamingPreviewEntryIds[messageId] = entryId
            messages.append(.single(single))
            onMessagesChange?(.appended(messages[messages.count - 1]))
        }
    }

    /// Build a synthetic `Message2.assistant` carrying a single text content
    /// block — the partial-render shape. The text lands at content-block
    /// index 0, matching the common text-first assistant message so the
    /// finalized envelope's block ids converge (a message that opens with a
    /// thinking / tool block instead reflows once at finalize, never mid-stream).
    static func syntheticAssistantMessage(messageId: String, text: String) -> Message2 {
        let dict: [String: Any] = [
            "type": "assistant",
            "message": [
                "id": messageId,
                "type": "message",
                "role": "assistant",
                "content": [["type": "text", "text": text]],
            ],
        ]
        // The resolver is the same path JSONL replay uses; a malformed dict
        // can't happen here (we built it), so fall back to an empty assistant.
        if let resolved = try? Message2Resolver().resolve(dict) {
            return resolved
        }
        return .unknown(name: "assistant", raw: dict)
    }
}
