import Foundation

/// Which document a tab beside the transcript shows: a transcript file and
/// the id of what was opened in it (`TranscriptPage.document(for:)`).
///
/// It is the tab's identifier, so editor history can make the tab again
/// after it was closed, and opening the same thing twice finds the tab
/// already open.
nonisolated struct DocumentReference: Hashable, Sendable {
    let transcriptURL: URL
    let id: String

    /// The conversation of subagent `agentID`, beside this transcript's:
    /// `<session>/subagents/agent-<id>.jsonl`.
    func conversationURL(ofAgent agentID: String) -> URL {
        transcriptURL.deletingPathExtension()
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("agent-\(agentID).jsonl")
    }
}
