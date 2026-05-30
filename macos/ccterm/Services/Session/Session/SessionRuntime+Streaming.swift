import AgentSDK
import Foundation

// MARK: - Partial-message stream consumption
//
// The CLI is launched with `--include-partial-messages` (see
// `SessionConfig.toAgentSDKConfig`), so the SDK delivers SSE-style deltas on
// `Session.onStreamEvent`. `attachCallbacks` hops each event to the main actor
// and funnels it here. We consume only what we render:
//
//   • `text_delta` → live assistant text. Accumulated per message, run through
//     `StreamingMarkdownCommit` (holds incomplete code blocks / tables), and
//     surfaced as a *provisional* timeline entry that the finalized
//     `.assistant` envelope reuses in place (see `SessionRuntime+Receive`).
//   • `message_start` / `message_delta` usage → live turn token totals
//     (input + output, cache excluded), shown beside the running pill.
//
// `thinking_delta` / `input_json_delta` are ignored — thinking isn't rendered,
// and tool calls render through the finalized `onMessage` path unchanged.

extension SessionRuntime {

    /// Drop all per-turn streaming state. Called from `enqueueAndSend` when a
    /// new user turn starts.
    func resetStreamingTurn() {
        streamingAssembler.reset()
        streamingPreviewEntryIds = [:]
        lastStreamingCommit = nil
        publishTurnUsage(.zero)
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
    /// turn state, then coalesce a re-render.
    func consumeStreamEvent(_ event: Message2StreamEvent) {
        let outcome = streamingAssembler.consume(event)
        if outcome.startedMessage { lastStreamingCommit = nil }
        if outcome.textChanged || outcome.usageChanged {
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

    // MARK: - Coalesced flush

    /// Collapse a burst of deltas into one re-render per runloop tick. The
    /// scheduled task reads the *latest* assembler state, so intermediate
    /// deltas that landed before it ran are folded into a single update.
    private func scheduleStreamingFlush() {
        guard !streamingFlushScheduled else { return }
        streamingFlushScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.streamingFlushScheduled = false
            self.flushStreamingState()
        }
    }

    private func flushStreamingState() {
        // Usage first — cheap, always current.
        publishTurnUsage(streamingAssembler.turnUsage)

        guard let messageId = streamingAssembler.currentMessageId else { return }
        let committed = StreamingMarkdownCommit.committedPrefix(of: streamingAssembler.currentText)
        // Skip a text re-render when only usage moved (committed text
        // unchanged) — avoids re-typesetting the preview on usage-only ticks.
        guard committed != lastStreamingCommit else { return }
        lastStreamingCommit = committed
        guard !committed.isEmpty else { return }
        applyStreamingPreview(messageId: messageId, committedText: committed)
    }

    /// Surface (or update) the provisional assistant entry for the currently
    /// streaming message. Keyed by `message.id` so the finalized envelope
    /// reuses the same entry id and converges in place.
    private func applyStreamingPreview(messageId: String, committedText: String) {
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
