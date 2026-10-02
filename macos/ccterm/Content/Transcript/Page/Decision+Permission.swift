import AgentSDK
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
            return .deny(message: Self.refusal)
        case .alwaysAllow(let rule):
            // The suggestion that carries `rule`; when none does, whatever the
            // CLI suggested — the reader asked to stop being asked.
            let carrying = request.suggestions.filter { $0.rules.contains { $0.settingsJSON.stringValue == rule } }
            return .allow(updatedPermissions: carrying.isEmpty ? request.suggestions : carrying)
        case .keepPlanning:
            return .deny(message: "The user wants to keep planning.")
        case .answer(let answers):
            // `answers` maps each question's text to its chosen labels, joined
            // by ", " for several — the shape the tool's result records.
            var input = request.input.objectValue ?? [:]
            input["answers"] = .object(answers.mapValues { .string($0) })
            return .allow(updatedInput: .object(input))
        }
    }

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
