import Foundation

/// `askUserQuestion` child payload — Q&A elicitation tool. Body
/// stacks each question + its answer (or an "awaiting answer…"
/// placeholder when the answer is still pending) in a single
/// rounded card.
///
/// `label` is the human-facing header text (e.g. `"Asked 2 questions"`).
struct AskUserQuestionChild: Equatable, Sendable {
    let id: UUID
    let label: String
    let items: [Item]

    struct Item: Equatable, Sendable {
        let question: String
        let answer: String?
    }
}
