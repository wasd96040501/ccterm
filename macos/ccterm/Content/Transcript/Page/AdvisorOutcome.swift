import AgentSDK
import Foundation

/// What the advisor said to a `server_tool_use` of its own
/// (design/transcript/06-agent-messages.md *Talking out*): its answer — it is
/// in the same assistant message, never in a user message's tool result — and
/// the model that gave it.
///
/// A server tool has no `UserMessage` result, so the advisor's call carries
/// this beside the (empty) one other calls have.
nonisolated struct AdvisorOutcome: Sendable, Equatable {
    var content: AdvisorToolResultBlock.Content
    /// The advisor's model (`AssistantMessage.advisorModel`).
    var model: String?

    /// The advice in the clear, when there is some to open: not encrypted, not
    /// a refusal, not an error.
    var advice: String? {
        guard case .result(let text, let stopReason) = content, stopReason != Self.refusal,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// What the row says after *Asked the advisor*, tertiary: what the CLI says
    /// for an encrypted answer, the advice's first line, or why there is none.
    var detail: String? {
        switch content {
        case .redacted:
            return String(localized: "Reviewed the conversation")
        case .result(let text, let stopReason):
            if stopReason == Self.refusal { return String(localized: "Declined to advise") }
            return text.firstLine
        case .error(let code):
            return Self.words(forError: code)
        case .unknown:
            return nil
        }
    }

    /// The error code in words, as the CLI says it where it can.
    static func words(forError code: String) -> String {
        switch code {
        case "overloaded": String(localized: "Overloaded — try again shortly")
        case "too_many_requests": String(localized: "Too many requests — try again shortly")
        case "prompt_too_long": String(localized: "The conversation is too long for the advisor")
        case "max_uses_exceeded": String(localized: "Asked as often as this session allows")
        case "execution_time_exceeded": String(localized: "The advisor took too long")
        case "unavailable": String(localized: "The advisor is unavailable")
        default: String(localized: "Advisor unavailable (\(code))")
        }
    }

    private static let refusal = "refusal"
}
