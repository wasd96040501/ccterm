import Foundation

/// A session's history as the CLI stores it on disk
/// (`~/.claude/projects/<project>/<session id>.jsonl`).
///
/// The file is not the conversation in order: it holds abandoned branches
/// (rewinds, edits, retries), history from before a compaction, rewritten
/// duplicates, and parallel tool results off the main chain. `Transcript`
/// rebuilds the current branch the way the CLI does on `--resume`, so
/// ``messages`` matches what the model sees and what a live ``Session``
/// would have reported.
public struct Transcript: Sendable, Equatable {
    /// The current branch, oldest first: `.user` and `.assistant` messages,
    /// with `.system(.compactBoundary)` where the conversation was compacted.
    /// Prompts the CLI queued while busy are included as user messages.
    /// Subagent messages live in separate files and are not included.
    public var messages: [Message]
    public var metadata: SessionMetadata

    /// Reads and rebuilds a transcript file.
    public init(contentsOf url: URL) throws {
        self.init(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// Rebuilds a transcript from the file's contents. Malformed or torn
    /// lines are skipped.
    public init(data: Data) {
        let chain = TranscriptChain(data: data)
        messages = chain.messages()
        metadata = chain.metadata
    }
}
