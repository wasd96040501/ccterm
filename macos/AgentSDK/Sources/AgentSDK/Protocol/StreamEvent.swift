import Foundation

/// A raw Messages API streaming event, forwarded while a response streams.
///
/// Only emitted with ``SessionConfiguration/includePartialMessages``. The
/// finished block still arrives afterwards as an ``AssistantMessage``, which
/// should replace whatever was accumulated from these deltas.
public struct StreamEvent: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        /// A new API response began; later deltas belong to `messageID`.
        /// `usage` carries the prompt's input tokens (its output count is a
        /// placeholder until ``messageDelta(stopReason:usage:)``).
        case messageStart(messageID: String, model: String, usage: Usage?)
        /// Block `index` began. Text and thinking start empty; a tool call
        /// starts with its id and name and an empty input.
        case contentBlockStart(index: Int, block: ContentBlock)
        case contentBlockDelta(index: Int, delta: Delta)
        case contentBlockStop(index: Int)
        case messageDelta(stopReason: String?, usage: Usage?)
        case messageStop
        case ping
        case unknown(JSONValue)
    }

    /// An increment to the block being streamed.
    public enum Delta: Sendable, Equatable {
        case text(String)
        case thinking(String)
        /// A fragment of a tool call's input JSON; concatenate the fragments.
        case inputJSON(String)
        case signature(String)
        case unknown(JSONValue)
    }

    public var uuid: String
    public var sessionID: String
    /// The `Agent` tool call whose subagent is streaming; `nil` on the main
    /// thread.
    public var parentToolUseID: String?
    public var event: Event
}

// MARK: - Decodable

extension StreamEvent: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.uuid = c.lenient(String.self, "uuid") ?? ""
        self.sessionID = c.lenient(String.self, "session_id") ?? ""
        self.parentToolUseID = c.lenient(String.self, "parent_tool_use_id")
        self.event = try c.required(Event.self, "event")
    }
}

extension StreamEvent.Event: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        do {
            switch c.lenient(String.self, "type") {
            case "message_start":
                let message = try c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: "message")
                self = .messageStart(
                    messageID: try message.required(String.self, "id"),
                    model: message.lenient(String.self, "model") ?? "",
                    usage: message.lenient(Usage.self, "usage"))
            case "content_block_start":
                self = .contentBlockStart(
                    index: try c.required(Int.self, "index"),
                    block: try c.required(ContentBlock.self, "content_block"))
            case "content_block_delta":
                self = .contentBlockDelta(
                    index: try c.required(Int.self, "index"),
                    delta: try c.required(StreamEvent.Delta.self, "delta"))
            case "content_block_stop":
                self = .contentBlockStop(index: try c.required(Int.self, "index"))
            case "message_delta":
                let delta = try? c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: "delta")
                self = .messageDelta(
                    stopReason: delta?.lenient(String.self, "stop_reason"),
                    usage: c.lenient(Usage.self, "usage"))
            case "message_stop":
                self = .messageStop
            case "ping":
                self = .ping
            default:
                self = .unknown(decoder.rawValue())
            }
        } catch {
            self = .unknown(decoder.rawValue())
        }
    }
}

extension StreamEvent.Delta: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        do {
            switch c.lenient(String.self, "type") {
            case "text_delta": self = .text(try c.required(String.self, "text"))
            case "thinking_delta": self = .thinking(try c.required(String.self, "thinking"))
            case "input_json_delta": self = .inputJSON(try c.required(String.self, "partial_json"))
            case "signature_delta": self = .signature(try c.required(String.self, "signature"))
            default: self = .unknown(decoder.rawValue())
            }
        } catch {
            self = .unknown(decoder.rawValue())
        }
    }
}
