import AgentSDK
import DisplayModels
import Foundation

nonisolated extension Decision {
    /// What the CLI is told for `request`: allow or deny; *always allow* with
    /// the request's suggested rule added; a plan approved or sent back; a
    /// question allowed with its answers written into the tool's input
    /// (`updatedInput`), as the CLI reads them back.
    func permissionDecision(for request: PermissionRequest) -> PermissionDecision {
        switch self {
        case .allow, .approvePlan:
            return .allow()
        case .deny:
            // ⎋ on a question declines it, which the CLI words on its own.
            return .deny(message: Tools.AskUserQuestion.matches(request.toolName) ? Self.declined : Self.refusal)
        case .alwaysAllow(let rule):
            // The suggestion that carries `rule`; when none does, whatever the
            // CLI suggested — the reader asked to stop being asked.
            let carrying = request.suggestions.filter { $0.rules.contains { $0.settingsJSON.stringValue == rule } }
            return .allow(updatedPermissions: carrying.isEmpty ? request.suggestions : carrying)
        case .keepPlanning:
            return .deny(message: "The user wants to keep planning.")
        case .answer(let answers, let notes):
            // `answers` maps each question's text to its chosen labels, joined
            // by ", " for several — the shape the tool's result records.
            var input = request.input.objectValue ?? [:]
            input["answers"] = .object(answers.mapValues { .string($0) })
            // Notes go back as annotations: the question's text to the notes
            // and, when the chosen option had one, its preview.
            var annotations: [String: JSONValue] = [:]
            for question in request.input["questions"]?.arrayValue ?? [] {
                guard let text = question["question"]?.stringValue else { continue }
                var annotation: [String: JSONValue] = [:]
                if let note = notes[text], !note.isEmpty { annotation["notes"] = .string(note) }
                let chosen = answers[text]
                if let preview = question["options"]?.arrayValue?.first(where: {
                    $0["label"]?.stringValue == chosen
                })?["preview"]?.stringValue {
                    annotation["preview"] = .string(preview)
                }
                if !annotation.isEmpty { annotations[text] = .object(annotation) }
            }
            if !annotations.isEmpty { input["annotations"] = .object(annotations) }
            return .allow(updatedInput: .object(input))
        case .chatAbout(let answers, let notes):
            return .deny(message: Self.clarification(request, answers: answers, notes: notes))
        }
    }

    /// The CLI's own feedback for *Chat About This*: what the reader wants to
    /// do, then each question asked, any answer given so far and the notes the
    /// reader wrote for it.
    private static func clarification(
        _ request: PermissionRequest, answers: [String: String], notes: [String: String]
    ) -> String {
        var lines = [
            "The user wants to clarify these questions.",
            "    This means they may have additional information, context or questions for you.",
            "    Take their response into account and then reformulate the questions if appropriate.",
            "    Start by asking them what they would like to clarify.",
            "",
            "    Questions asked:",
        ]
        for question in request.input["questions"]?.arrayValue ?? [] {
            guard let text = question["question"]?.stringValue else { continue }
            lines.append("- \"\(text)\"")
            lines.append(answers[text].map { "  Answer: \($0)" } ?? "  (No answer provided)")
            if let note = notes[text], !note.isEmpty { lines.append("  User notes: \(note)") }
        }
        return lines.joined(separator: "\n")
    }

    /// The CLI's words for a question the reader set aside with ⎋.
    private static let declined = "User declined to answer questions"

    /// The CLI's own words for a call the reader refused; the page reads a
    /// denied call back by this prefix (`TranscriptPageBuilder`).
    private static let refusal =
        "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed."
}

nonisolated extension PermissionUpdate {
    /// The rules of an add-rules update; none for any other kind.
    fileprivate var rules: [PermissionRule] {
        if case .addRules(let rules, _, _) = self { rules } else { [] }
    }
}
