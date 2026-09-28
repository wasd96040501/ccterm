import Foundation

/// One message the CLI emits on its output stream.
///
/// Decoding is stateless and never fails on content: a kind this SDK does not
/// model, or a known kind too malformed to decode, arrives as
/// ``unknown(_:)`` with the original JSON, so nothing is lost and nothing
/// crashes.
public enum Message: Sendable, Equatable {
    case assistant(AssistantMessage)
    case user(UserMessage)
    /// End of a turn.
    case result(ResultMessage)
    case system(SystemMessage)
    /// A streaming delta (``SessionConfiguration/includePartialMessages``).
    case streamEvent(StreamEvent)
    case toolProgress(ToolProgress)
    case rateLimit(RateLimitInfo)
    case commandLifecycle(CommandLifecycle)
    /// A suggested next prompt, emitted after a turn's result.
    case promptSuggestion(String)
    case unknown(JSONValue)
}

extension Message {
    /// Decodes one line of stream-json output (or of an export of it).
    ///
    /// Returns `nil` only when the line is not a JSON object.
    public init?(jsonLine: Data) {
        guard let message = try? JSONDecoder().decode(Message.self, from: jsonLine) else { return nil }
        self = message
    }
}

extension Message: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        switch c.lenient(String.self, "type") {
        case "assistant": self = Self.decode(decoder, Message.assistant)
        case "user": self = Self.decode(decoder, Message.user)
        case "result": self = Self.decode(decoder, Message.result)
        case "system": self = Self.decode(decoder, Message.system)
        case "stream_event": self = Self.decode(decoder, Message.streamEvent)
        case "tool_progress": self = Self.decode(decoder, Message.toolProgress)
        case "rate_limit_event": self = Self.decode(decoder, Message.rateLimit)
        case "command_lifecycle": self = Self.decode(decoder, Message.commandLifecycle)
        case "prompt_suggestion":
            if let suggestion = c.lenient(String.self, "suggestion") {
                self = .promptSuggestion(suggestion)
            } else {
                self = .unknown(decoder.rawValue())
            }
        default:
            self = .unknown(decoder.rawValue())
        }
    }

    private static func decode<T: Decodable>(_ decoder: Decoder, _ wrap: (T) -> Message) -> Message {
        if let value = try? T(from: decoder) { return wrap(value) }
        return .unknown(decoder.rawValue())
    }
}
