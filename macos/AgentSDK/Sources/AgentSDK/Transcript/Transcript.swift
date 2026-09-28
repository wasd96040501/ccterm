import Foundation

/// A session's conversation, read from the file the CLI keeps for it
/// (`~/.claude/projects/<project>/<session id>.jsonl`).
///
/// ``messages`` are the conversation a live ``Session`` would have emitted
/// had it run the whole session, from the first prompt to the last reply —
/// its `.user` and `.assistant` messages and compaction boundaries, not the
/// results, status and stream events around them. Reading the file gives
/// what watching the session live gave. How the file stores them — a tree
/// of rows, one row per content block, rewritten duplicates, abandoned
/// branches — stays inside.
public struct Transcript: Sendable, Equatable {
    /// The conversation, oldest first: `.user` and `.assistant` messages,
    /// as a live ``Session`` emits them.
    ///
    /// - A compaction is a `.system(.compactBoundary)` where it happened, and
    ///   everything before it stays.
    /// - A rewind or an edited prompt leaves the conversation as the user
    ///   continued it; the messages they went back over are not included.
    /// - A local command (`/compact`) comes before its output, as it was
    ///   run; the stream echoes it after.
    /// - Prompts the CLI queued while busy are user messages.
    /// - A subagent's messages live in its own file, which reads as that
    ///   subagent's conversation.
    public var messages: [Message]
    public var metadata: SessionMetadata

    /// Reads a session file.
    public init(contentsOf url: URL) throws {
        self.init(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// Reads a session file's contents. Malformed or torn lines are skipped.
    public init(data: Data) {
        let chain = TranscriptChain(data: data)
        messages = chain.messages()
        metadata = chain.metadata
    }
}
