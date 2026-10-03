import AgentSDK
import DisplayModels
import Foundation

/// A message another agent put into the conversation — a subagent, another
/// session, the coordinator, a plugin (design/transcript/06-agent-messages.md).
///
/// A subagent's message is its report: work it did, like a diff, so it is one
/// line on the page and its words open beside. Anyone else is talking to
/// Claude, and gets the page: a caption naming them over their words, quoted.
nonisolated struct AgentMessage: Sendable, Equatable, Identifiable {
    let id: String
    let sender: UserMessage.Sender
    /// Who is speaking, as the caption says it: a subagent's description when
    /// the page knows the call that started it, a session's name, …
    let name: String
    /// What they said, as markdown.
    let text: String
    /// The line a subagent's report is on the page.
    let line: WorkLine

    /// Whether the words open beside rather than on the page: a subagent's
    /// report.
    var opensBeside: Bool {
        if case .agent = sender { true } else { false }
    }

    /// The caption over the words of a message that stays on the page: the
    /// sidebar's glyph for the party, and their name.
    var caption: Caption {
        // A plugin says when it spoke: it started this turn in the reader's
        // place, or steered one already running.
        if case .plugin(_, let duringTurn) = sender {
            return Caption(
                glyph: .plugin, text: String(localized: "Plugin “\(name)”"),
                detail: duringTurn ? String(localized: "While Claude worked") : String(localized: "Started this turn"))
        }
        let glyph: Caption.Glyph =
            switch sender {
            case .agent: .subagent
            case .session: .session
            case .coordinator: .coordinator
            case .plugin: .plugin
            }
        return Caption(glyph: glyph, text: name)
    }
}
