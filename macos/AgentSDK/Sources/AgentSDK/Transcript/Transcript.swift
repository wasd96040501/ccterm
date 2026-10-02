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

    /// A conversation as given: a stand-in for previews and tests, or the
    /// start of one a live ``Session`` goes on with (``append(_:)``).
    public init(messages: [Message], metadata: SessionMetadata = SessionMetadata()) {
        self.messages = messages
        self.metadata = metadata
    }

    /// Adds what a live ``Session`` emitted, by the rules the file is read
    /// by, so a transcript kept live equals the file read afterwards
    /// (TranscriptSmoke checks both on the real CLI):
    ///
    /// - Only `.user`, `.assistant` and `.system(.compactBoundary)` are kept;
    ///   results, status, stream events and the rest are ignored.
    /// - A subagent's messages (`parentToolUseID` set) are its own file's,
    ///   not this conversation's.
    /// - A prompt replayed as it enters a turn is kept once (its uuid).
    /// - A local command comes before its output, as it was run; the stream
    ///   echoes it after.
    public mutating func append(_ message: Message) {
        switch message {
        case .user(let user):
            guard user.parentToolUseID == nil else { return }
            if let uuid = user.uuid, messages.contains(where: { $0.isUser(uuid) }) { return }
            if user.isReplay, user.kind.isLocalCommand, let run = trailingCommandOutputs {
                // The echo of a command whose output came first. An earlier
                // command's output before this run has its echo already in
                // place, so only the run's last output is this command's then.
                let precededByCommand = run.lowerBound > 0 && messages[run.lowerBound - 1].isUserCommand
                messages.insert(message, at: precededByCommand ? run.upperBound - 1 : run.lowerBound)
                return
            }
            messages.append(message)
        case .assistant(let assistant):
            guard assistant.parentToolUseID == nil else { return }
            messages.append(message)
        case .system(.compactBoundary):
            messages.append(message)
        default:
            return
        }
    }

    /// The run of local-command outputs at the end of ``messages``.
    private var trailingCommandOutputs: Range<Int>? {
        var start = messages.count
        while start > 0, messages[start - 1].isCommandOutput { start -= 1 }
        return start == messages.count ? nil : start..<messages.count
    }

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

extension UserMessage.Kind {
    fileprivate var isLocalCommand: Bool {
        switch self {
        case .slashCommand, .shellCommand: return true
        default: return false
        }
    }
}

extension Message {
    fileprivate func isUser(_ uuid: String) -> Bool {
        if case .user(let user) = self { return user.uuid == uuid }
        return false
    }

    fileprivate var isCommandOutput: Bool {
        if case .user(let user) = self, case .commandOutput = user.kind { return true }
        return false
    }

    fileprivate var isUserCommand: Bool {
        if case .user(let user) = self { return user.kind.isLocalCommand }
        return false
    }
}
