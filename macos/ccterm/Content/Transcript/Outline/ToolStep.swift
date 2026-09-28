import Foundation

/// One tool call and how it went, as a card lists it: already worded, already
/// counted, with what it opens.
nonisolated struct ToolStep: Sendable, Equatable {
    /// What a group's summary counts it as.
    enum Kind: Sendable, Equatable, CaseIterable {
        case read
        case edit
        case command
        case search
        case web
        case agent
        case other
    }

    enum Outcome: Sendable, Equatable {
        case succeeded
        case failed
        /// The user stopped it, or refused it.
        case stopped
        /// No result was recorded — the conversation ended, or was cut, first.
        case pending
    }

    /// What the row says at its trailing end.
    enum Stat: Sendable, Equatable {
        /// Lines added and removed.
        case lines(added: Int, removed: Int)
        case note(String)
    }

    /// The tool call's id.
    var id: String
    var kind: Kind
    var symbol: String
    /// What happened, in a few words: a file's name, a command's summary.
    var title: String
    /// Where or with what, secondary: a folder, the command itself.
    var detail: String?
    /// `detail` is code (a command, a pattern) and is set in the code face.
    var detailIsCode: Bool = false
    var stat: Stat?
    var outcome: Outcome
    var document: ToolDocument?
}
