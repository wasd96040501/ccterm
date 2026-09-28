import AgentSDK
import Foundation

// MARK: - JSONL path resolution

extension SessionRuntime {

    /// History JSONL URL for this session. Thin forwarder over
    /// `HistoryLoader.locate`, paired with the handle's own `repository` for
    /// slug lookup. Loading it is `Session.loadHistory()`'s job
    /// (`TranscriptBackfillPipeline` over a `TranscriptPageSource`); the
    /// runtime owns only the `historyLoadState` flag.
    var historyJSONLURL: URL? {
        HistoryLoader.locate(
            sessionId: sessionId,
            slug: repository.find(sessionId)?.slug)
    }
}
