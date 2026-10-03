import Foundation

/// A hairline across the column where the session's shape changed
/// (design/transcript/05-local.md): it was compacted, it ended and was
/// resumed, or it was left alone for more than an hour.
public nonisolated struct SessionDivider: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: Kind
    /// The compaction summary the model continued from — what *Summary*
    /// opens beside. Only a compaction has one.
    public let summary: String?
    /// The words the CLI wrote to start a turn nobody typed — what *Prompt*
    /// opens beside (design/transcript/06-agent-messages.md).
    public let prompt: String?
    /// The words centred on the hairline (05-local.md): *Conversation
    /// compacted · 168k → 14k tokens*, *Compacted automatically*,
    /// *Compacting…*, *Resumed · Tue 14:02*, or the time after a pause. Worded
    /// when the page is built.
    public let label: String
    /// The link after the label: *Summary* of a compaction, *Prompt* of a turn
    /// the CLI started; `nil` when there is nothing to open.
    public let linkTitle: String?

    public init(
        id: String, kind: Kind, summary: String?, prompt: String?, label: String, linkTitle: String?
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.prompt = prompt
        self.label = label
        self.linkTitle = linkTitle
    }

    /// Why the CLI started a turn on its own.
    public enum Continuation: Sendable, Equatable {
        case usageLimitReset
        /// A plan approved in the browser (ultraplan), handed back.
        case planApproved
        /// A goal the reader set with `/goal`: they started it, so it has its
        /// own words.
        case goal
        case automatic
    }

    public enum Kind: Sendable, Equatable {
        /// `/compact`, or the CLI's own. Token counts when the boundary
        /// recorded them.
        case compacted(automatically: Bool, preTokens: Int?, postTokens: Int?)
        /// Compacting now: the travelling arc, *Compacting…*.
        case compacting
        /// The session ended with `/exit` and was resumed at this time.
        case resumed(Date)
        /// Nothing happened for more than an hour; the time the next row came.
        case pause(Date)
        /// The CLI started a turn with its own words.
        case continued(Continuation)
        /// The session was ended and resumed in another account, on a model
        /// (design/transcript/08-live.md *Another account restarts the session*).
        case restarted(account: String, model: String)
    }

    /// What the link opens beside.
    public var opensDocument: Bool { linkTitle != nil }
}
