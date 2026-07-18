import AgentSDK

/// UI-free seam for reading a session's persisted history, defined on the
/// ccterm side (AgentSDK is not modified). Injected into `TranscriptStore`
/// as a metatype (`.Type`): production hands `SessionHistory.self`, tests
/// hand a fake `enum` that returns canned `[Message2]`. This keeps the
/// store off a hard-coded `SessionHistory` call and gives tests a seam.
///
/// Static-only because `SessionHistory` is a caseless `enum` whose reads
/// are already `static` — so `extension SessionHistory: TranscriptHistoryService {}`
/// is a zero-body conformance with no adapter type.
///
/// The single method is the whole-history blocking read the first cut
/// needs; paging / streaming methods are reserved for later.
protocol TranscriptHistoryService {
    static func loadMessages(sessionId: String) -> [Message2]
}

extension SessionHistory: TranscriptHistoryService {}
