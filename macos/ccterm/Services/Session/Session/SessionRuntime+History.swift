import AgentSDK
import Foundation

// MARK: - JSONL path resolution

extension SessionRuntime {

    /// History JSONL URL for this session. Thin forwarder over
    /// `HistoryLoader.locate`, paired with the handle's own
    /// `repository` for slug lookup.
    ///
    /// History **load** orchestration no longer lives here: the old two-phase
    /// (Phase A tail + Phase B prefix) read, its `tailBaseline` / `newTailStart`
    /// offset math, the throwaway in-memory `SessionRuntime` that `buildEntries`
    /// spun up, and `ToolResultReresolver` are all deleted.
    /// `Session.loadHistory()` now drives a
    /// `TranscriptBackfillPipeline` over a `JSONLReversePageSource`: a single
    /// reverse-streaming read that emits already-paired blocks straight into
    /// the controller, with the runtime owning only the `historyLoadState`
    /// lifecycle flag.
    var historyJSONLURL: URL? {
        HistoryLoader.locate(
            sessionId: sessionId,
            slug: repository.find(sessionId)?.slug)
    }
}
