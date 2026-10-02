import AgentSDK
import Foundation

/// What Claude said to another party with `SendMessage`
/// (design/transcript/06-agent-messages.md *Talking out*): to whom, the summary
/// the model gave, and the message — or, for a structured one, what it does.
nonisolated struct SentMessage: Sendable, Equatable {
    /// A message the tool carries as a request rather than as words.
    enum Request: Sendable, Equatable {
        case shutdown
        case plan(approved: Bool)
    }

    /// Who it went to: a name, or `*` for the whole team.
    let to: String
    let summary: String
    /// The words, as markdown; a structured message as its JSON.
    let body: String
    let request: Request?

    var isTeam: Bool { to == "*" }

    /// *team-lead*, or *the team*.
    var party: String { isTeam ? String(localized: "the team") : to }

    /// What was sent, as the run's sentence says it for one message:
    /// *Messaged team-lead*, *Messaged the team*, and for a structured one
    /// what it did — *Asked qa to shut down*, *Approved qa's plan*.
    var action: String? {
        switch request {
        case .shutdown?: String(localized: "Asked \(to) to shut down")
        case .plan(let approved)?:
            approved ? String(localized: "Approved \(to)’s plan") : String(localized: "Sent \(to)’s plan back")
        case nil: nil
        }
    }

    /// `input`, read in either shape the tool has had: `{to, summary, message}` and
    /// the older `{type, recipient, content}`.
    init?(_ input: JSONValue) {
        guard let to = input["to"]?.stringValue ?? input["recipient"]?.stringValue else { return nil }
        self.to = to
        summary = input["summary"]?.stringValue ?? ""
        let message = input["message"] ?? input["content"]
        var request: Request?
        let kind = message?["type"]?.stringValue ?? input["type"]?.stringValue
        switch kind {
        case "shutdown_request": request = .shutdown
        case "plan_approval_response": request = .plan(approved: message?["approve"]?.boolValue ?? true)
        default: break
        }
        self.request = request
        if let text = message?.stringValue {
            body = text
        } else if let message {
            body = Self.json(message)
        } else {
            body = ""
        }
    }

    private static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "" }
        return "```json\n\(text)\n```"
    }
}
