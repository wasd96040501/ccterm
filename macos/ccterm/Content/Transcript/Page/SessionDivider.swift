import Foundation

/// A hairline across the column where the session's shape changed
/// (design/transcript/05-local.md): it was compacted, it ended and was
/// resumed, or it was left alone for more than an hour.
nonisolated struct SessionDivider: Sendable, Equatable, Identifiable {
    let id: String
    let kind: Kind
    /// The compaction summary the model continued from — what *Summary*
    /// opens beside. Only a compaction has one.
    var summary: String?

    enum Kind: Sendable, Equatable {
        /// `/compact`, or the CLI's own. Token counts when the boundary
        /// recorded them.
        case compacted(automatically: Bool, preTokens: Int?, postTokens: Int?)
        /// Compacting now: the travelling arc, *Compacting…*.
        case compacting
        /// The session ended with `/exit` and was resumed at this time.
        case resumed(Date)
        /// Nothing happened for more than an hour; the time the next row came.
        case pause(Date)
    }
}
