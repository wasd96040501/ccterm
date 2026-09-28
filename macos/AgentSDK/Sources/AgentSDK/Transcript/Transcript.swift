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

    /// Reads a session file's metadata from its first and last 64 KB only,
    /// so listing many sessions costs the same whatever their length. The
    /// CLI appends title and prompt rows as the session goes, so the tail
    /// holds the latest; ``SessionMetadata/cwd`` is the first one found.
    /// ``SessionMetadata/createdAt`` and ``SessionMetadata/updatedAt`` are
    /// bounds of the rows read, not of the whole file.
    public static func metadata(contentsOf url: URL) throws -> SessionMetadata {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let window = UInt64(metadataSliceSize)
        var data = try handle.read(upToCount: metadataSliceSize) ?? Data()
        if size > window * 2 {
            try handle.seek(toOffset: size - window)
            // The slices meet mid-line; a torn line on either side is skipped.
            data.append(UInt8(ascii: "\n"))
            data.append(try handle.readToEnd() ?? Data())
        } else if size > window {
            data.append(try handle.readToEnd() ?? Data())
        }
        return TranscriptChain(data: data).metadata
    }

    private static let metadataSliceSize = 64 * 1024
}
