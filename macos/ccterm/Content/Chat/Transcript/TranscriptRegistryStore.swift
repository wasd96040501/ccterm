import Foundation

/// App-scope registry of per-transcript `TranscriptStore` instances.
///
/// Owned by `AppDelegate` at the composition root and threaded down via
/// `AppContext`. Its job is to keep parsed blocks + typeset layouts alive
/// across VC lifecycle: the `TranscriptViewController` dies on sidebar
/// switch-away, but the store it was reading from stays put here, so
/// switch-back is O(rows visible) instead of O(history).
///
/// Not a plain `[String: TranscriptStore]` inline on `AppContext`
/// because the dict needs a mutating "get-or-create" entry point and
/// `AppContext` is a read-only manifest struct (`let` fields only).
/// A registry `class` gives us that write surface without breaking the
/// manifest's read-only contract.
@MainActor
final class TranscriptRegistryStore {

    private var stores: [String: TranscriptStore] = [:]

    init() {}

    /// Get-or-create the store for a transcript id. Same id → same
    /// instance across the process lifetime.
    func store(for transcriptId: String) -> TranscriptStore {
        if let s = stores[transcriptId] { return s }
        let s = TranscriptStore(transcriptId: transcriptId)
        stores[transcriptId] = s
        return s
    }

    /// Called from `SessionManager` on archive / delete of a session, or
    /// from tests. Nothing else calls this — sidebar switch-away and
    /// window close deliberately leave the store alive.
    func discard(_ transcriptId: String) {
        stores.removeValue(forKey: transcriptId)
    }

    nonisolated deinit {}
}
