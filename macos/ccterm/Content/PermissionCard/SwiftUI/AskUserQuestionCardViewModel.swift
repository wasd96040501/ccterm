import SwiftUI
import Observation
import AgentSDK

@Observable
final class AskUserQuestionCardViewModel {
    let request: PermissionRequest
    let questions: [ParsedQuestion]
    var answers: [QuestionAnswer]
    private let onDecision: (PermissionDecision) -> Void

    struct ParsedQuestion: Identifiable {
        let id: Int
        let question: String
        let header: String?
        let options: [ParsedOption]
    }

    struct ParsedOption: Identifiable {
        let id: Int
        let label: String
        let description: String?
        let preview: String?
    }

    struct QuestionAnswer {
        var selectedIndex: Int?
        var otherText: String = ""
    }

    var allAnswered: Bool {
        zip(questions, answers).allSatisfy { q, a in
            guard let idx = a.selectedIndex else { return false }
            if idx == q.options.count {
                return !a.otherText.trimmingCharacters(in: .whitespaces).isEmpty
            }
            return idx >= 0 && idx < q.options.count
        }
    }

    init(request: PermissionRequest, onDecision: @escaping (PermissionDecision) -> Void) {
        self.request = request
        self.onDecision = onDecision
        let parsed = Self.parseQuestions(from: request)
        self.questions = parsed
        self.answers = Array(repeating: QuestionAnswer(), count: max(parsed.count, 1))
    }

    func confirm() {
        var answersDict: [String: String] = [:]
        var annotationsDict: [String: [String: String]] = [:]
        for (q, a) in zip(questions, answers) {
            guard let idx = a.selectedIndex else { continue }
            if idx == q.options.count {
                let text = a.otherText.trimmingCharacters(in: .whitespacesAndNewlines)
                answersDict[q.question] = text
                annotationsDict[q.question] = ["notes": text]
            } else {
                let opt = q.options[idx]
                answersDict[q.question] = opt.label
                if let preview = opt.preview {
                    annotationsDict[q.question] = ["preview": preview]
                }
            }
        }
        let updatedInput: [String: Any] = [
            "questions": request.rawInput["questions"] as Any,
            "answers": answersDict,
            "annotations": annotationsDict,
        ]
        onDecision(request.allowOnce(updatedInput: updatedInput))
    }

    func deny() {
        onDecision(.deny(reason: "User rejected answering questions", interrupt: true))
    }

    private static func parseQuestions(from request: PermissionRequest) -> [ParsedQuestion] {
        guard let questionsRaw = request.rawInput["questions"] as? [[String: Any]] else { return [] }
        return questionsRaw.enumerated().map { idx, dict in
            let question = dict["question"] as? String ?? ""
            let header = dict["header"] as? String
            let optionsRaw = dict["options"] as? [[String: Any]] ?? []
            let options = optionsRaw.enumerated().map { oIdx, oDict in
                ParsedOption(
                    id: oIdx,
                    label: oDict["label"] as? String ?? "",
                    description: oDict["description"] as? String,
                    preview: oDict["preview"] as? String
                )
            }
            return ParsedQuestion(id: idx, question: question, header: header, options: options)
        }
    }
}
