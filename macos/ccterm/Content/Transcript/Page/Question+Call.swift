import AgentSDK
import DisplayModels
import Foundation

nonisolated extension Question {
    /// The question of the `AskUserQuestion` call `call`, worded; the page
    /// keeps the call beside it (`TranscriptEntry.question`).
    ///
    /// `answers` are the chosen labels by question text, several joined by
    /// `", "`, as the tool reports them. An answer that is none of the options
    /// was typed: it shows as one more option, chosen, as *Other*.
    init(call: ToolCall, questions: [Tools.AskUserQuestion.Question], answers: [String: String]) {
        let items = questions.map { question in
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
        let isWaiting: Bool
        if case .waiting = call.state { isWaiting = true } else { isWaiting = false }
        let message: String?
        if case .failed(let text) = call.state { message = text } else { message = nil }
        let isTalkedOver = message?.hasPrefix(Self.clarifying) ?? false
        let outcome: String?
        if let message {
            if isTalkedOver {
                outcome = String(localized: "Not answered — talked over in the conversation")
            } else if message.hasPrefix(Self.declined) {
                outcome = String(localized: "Not answered")
            } else {
                outcome = nil
            }
        } else {
            outcome = call.state == .denied ? String(localized: "Not answered") : nil
        }
        self.init(id: call.id, items: items, isWaiting: isWaiting, outcome: outcome, isTalkedOver: isTalkedOver)
    }

    private static let clarifying = "The user wants to clarify these questions"
    private static let declined = "User declined to answer questions"

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
