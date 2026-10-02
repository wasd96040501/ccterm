import Foundation

/// One thing on the page, in reading order — the closed vocabulary of what a
/// transcript shows. Conversation (a prompt, a reply, another agent's
/// message, a question, a plan) gets the page; work (a run, news, a local
/// command, a subagent's report) gets a line.
///
/// An entry is not a row: most are one, a message or a plan is a caption row
/// and a markdown row (`PageRow.rows`).
nonisolated enum TranscriptEntry: Sendable, Equatable, Identifiable {
    /// What the reader typed.
    case prompt(PromptEntry)
    /// What the model wrote, as markdown.
    case reply(id: String, markdown: String)
    case run(ToolRun)
    case news(NewsRun)
    case command(LocalCommand)
    case divider(SessionDivider)
    /// The reader stopped the model while it was writing: a mark under the
    /// reply before it.
    case interruption(id: String)
    case agentMessage(AgentMessage)
    case question(Question)
    case plan(Plan)

    var id: String {
        switch self {
        case .prompt(let prompt): prompt.id
        case .reply(let id, _), .interruption(let id): id
        case .run(let run): run.id
        case .news(let news): news.id
        case .command(let command): command.id
        case .divider(let divider): divider.id
        case .agentMessage(let message): message.id
        case .question(let question): question.id
        case .plan(let plan): plan.id
        }
    }
}
