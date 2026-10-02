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
            /// 12-pt tertiary under the label; may be empty.
            let detail: String
            let isChosen: Bool
            /// Shown beside the list, monospaced, while this option is picked
            /// (single-select only).
            var preview: String? = nil
        }

        let header: String
        let text: String
        /// What the model offered; an answer that was typed (*Other*) is one more,
        /// chosen, with *Other* as its detail.
        let options: [Option]
        /// Checkboxes rather than radio buttons while it waits.
        let allowsSeveral: Bool

        /// After the header of a multi-select question.
        var hint: String? { allowsSeveral ? String(localized: "Choose any") : nil }

        /// Whether a preview is shown beside the options while it waits.
        var hasPreviews: Bool { !allowsSeveral && options.contains { $0.preview != nil } }

        /// The row the reader types an answer in, always last while it waits:
        /// *Other — type something*.
        var otherLabel: String { String(localized: "Other — type something") }
        var otherPlaceholder: String {
            allowsSeveral ? String(localized: "Type something") : String(localized: "Type something.")
        }
        /// Under a previewed option, where the reader's words go back as *User notes*.
        var notesPlaceholder: String { String(localized: "Notes") }
    }

    let call: ToolCall
    let items: [Item]

    var id: String { call.id }

    /// Waiting for the reader's answer: the options are controls, and
    /// **Submit** answers.
    var isWaiting: Bool {
        if case .waiting = call.state { true } else { false }
    }

    /// What a question the reader didn't answer says under it: *Not answered —
    /// talked over in the conversation* after *Chat About This*, *Not answered*
    /// after ⎋. `nil` for an answered or waiting one.
    var outcome: String? {
        guard case .failed(let message) = call.state else {
            return call.state == .denied ? String(localized: "Not answered") : nil
        }
        if message.hasPrefix(Self.clarifying) {
            return String(localized: "Not answered — talked over in the conversation")
        }
        if message.hasPrefix(Self.declined) { return String(localized: "Not answered") }
        return nil
    }

    private static let clarifying = "The user wants to clarify these questions"
    private static let declined = "User declined to answer questions"

    /// `questionmark.bubble`, coral while it waits.
    var tile: Tile { Tile(glyph: .question, state: isWaiting ? .waiting : .done) }

    /// `answers` are the chosen labels by question text, several joined by
    /// `", "`, as the tool reports them. An answer that is none of the options
    /// was typed: it shows as one more option, chosen, as *Other*.
    init(call: ToolCall, questions: [Tools.AskUserQuestion.Question], answers: [String: String]) {
        self.call = call
        items = questions.map { question in
            let given = answers[question.question]
            let labels = Set(question.options.map(\.label))
            let chosen = given.map { answer in Set([answer] + answer.components(separatedBy: ", ")) }
            var options = question.options.map {
                Item.Option(
                    label: $0.label, detail: $0.description, isChosen: chosen?.contains($0.label) ?? false,
                    preview: $0.preview)
            }
            if let given, !given.isEmpty {
                for text in Self.typed(given, labels: labels, several: question.multiSelect) {
                    options.append(Item.Option(label: text, detail: String(localized: "Other"), isChosen: true))
                }
            }
            return Item(
                header: question.header, text: question.question, options: options,
                allowsSeveral: question.multiSelect)
        }
    }

    /// The parts of `answer` that are not an option's label.
    private static func typed(_ answer: String, labels: Set<String>, several: Bool) -> [String] {
        if labels.contains(answer) { return [] }
        guard several else { return [answer] }
        let parts = answer.components(separatedBy: ", ")
        let unknown = parts.filter { !labels.contains($0) }
        if unknown.isEmpty { return [] }
        // A typed answer may itself hold ", ": when no part is a label it is one.
        return unknown.count == parts.count ? [answer] : unknown
    }
}
