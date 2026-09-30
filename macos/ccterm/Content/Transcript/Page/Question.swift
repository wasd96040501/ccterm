import AgentSDK
import Foundation

/// An `AskUserQuestion` call: questions put to the reader, and the answers
/// given — kept together, like a form filled in
/// (design/transcript/07-talk.md). It breaks out of the run around it.
nonisolated struct Question: Sendable, Equatable, Identifiable {
    /// One question as the row shows it: the header as its title, the
    /// question, and the options with the chosen ones marked.
    struct Item: Sendable, Equatable {
        struct Option: Sendable, Equatable {
            let label: String
            /// 12-pt tertiary beside the label; may be empty.
            let detail: String
            let isChosen: Bool
        }

        let header: String
        let text: String
        let options: [Option]
        /// Checkboxes rather than radio buttons while it waits.
        let allowsSeveral: Bool
    }

    let call: ToolCall
    let items: [Item]

    var id: String { call.id }

    /// Waiting for the reader's answer: the options are controls, and
    /// **Submit** answers.
    var isWaiting: Bool {
        if case .waiting = call.state { true } else { false }
    }

    /// `questionmark.bubble`, coral while it waits.
    var tile: Tile { Tile(glyph: .question, state: isWaiting ? .waiting : .done) }

    /// `answers` are the chosen labels by question text, several joined by
    /// `", "`, as the tool reports them.
    init(call: ToolCall, questions: [Tools.AskUserQuestion.Question], answers: [String: String]) {
        self.call = call
        items = questions.map { question in
            let chosen = answers[question.question].map { answer in
                Set([answer] + answer.components(separatedBy: ", "))
            }
            return Item(
                header: question.header, text: question.question,
                options: question.options.map {
                    Item.Option(label: $0.label, detail: $0.description, isChosen: chosen?.contains($0.label) ?? false)
                }, allowsSeveral: question.multiSelect)
        }
    }
}
