import Foundation

/// One block of a message's `content`, as the Anthropic Messages API defines
/// it. Block types this SDK does not model (`document`, `tool_reference`,
/// server-tool blocks, …) arrive as ``unknown(type:raw:)`` with the full
/// original JSON.
public enum ContentBlock: Sendable, Equatable {
    case text(String)
    case thinking(String)
    /// Encrypted thinking the API returns instead of plain text.
    case redactedThinking(String)
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)
    case image(ImageBlock)
    /// A call to a tool the API runs itself (`server_tool_use`) — the advisor.
    case serverToolUse(ServerToolUseBlock)
    /// The advisor's answer to a ``serverToolUse(_:)``, in the same assistant
    /// message (`advisor_tool_result`).
    case advisorToolResult(AdvisorToolResultBlock)
    case unknown(type: String, raw: JSONValue)
}

extension ContentBlock {
    /// The text of a `.text` block.
    public var text: String? {
        if case .text(let s) = self { return s }
        return nil
    }
}

// MARK: - Codable

extension ContentBlock: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        let type = c.lenient(String.self, "type") ?? ""
        do {
            switch type {
            case "text":
                self = .text(try c.required(String.self, "text"))
            case "thinking":
                self = .thinking(try c.required(String.self, "thinking"))
            case "redacted_thinking":
                self = .redactedThinking(try c.required(String.self, "data"))
            case "tool_use":
                self = .toolUse(
                    ToolUseBlock(
                        id: try c.required(String.self, "id"),
                        name: try c.required(String.self, "name"),
                        input: c.lenient(JSONValue.self, "input") ?? .object([:])))
            case "tool_result":
                self = .toolResult(
                    ToolResultBlock(
                        toolUseID: try c.required(String.self, "tool_use_id"),
                        content: c.contentBlocks("content") ?? [],
                        isError: c.lenient(Bool.self, "is_error") ?? false))
            // TODO(fill A): "server_tool_use", "advisor_tool_result" (protocol.md *The advisor*).
            case "image":
                self = .image(ImageBlock(source: Self.imageSource(c.lenient(JSONValue.self, "source") ?? .null)))
            default:
                self = .unknown(type: type, raw: decoder.rawValue())
            }
        } catch {
            self = .unknown(type: type, raw: decoder.rawValue())
        }
    }

    private static func imageSource(_ raw: JSONValue) -> ImageBlock.Source {
        switch raw["type"]?.stringValue {
        case "base64":
            if let media = raw["media_type"]?.stringValue, let data = raw["data"]?.stringValue {
                return .base64(mediaType: media, data: data)
            }
        case "url":
            if let url = raw["url"]?.stringValue { return .url(url) }
        default:
            break
        }
        return .unknown(raw)
    }

    public func encode(to encoder: Encoder) throws {
        try jsonValue.encode(to: encoder)
    }

    /// The wire form of this block.
    var jsonValue: JSONValue {
        switch self {
        case .text(let text):
            return ["type": "text", "text": .string(text)]
        case .thinking(let thinking):
            return ["type": "thinking", "thinking": .string(thinking)]
        case .redactedThinking(let data):
            return ["type": "redacted_thinking", "data": .string(data)]
        case .toolUse(let block):
            return ["type": "tool_use", "id": .string(block.id), "name": .string(block.name), "input": block.input]
        case .toolResult(let block):
            return [
                "type": "tool_result", "tool_use_id": .string(block.toolUseID),
                "content": .array(block.content.map(\.jsonValue)), "is_error": .bool(block.isError),
            ]
        case .image(let block):
            let source: JSONValue
            switch block.source {
            case .base64(let media, let data):
                source = ["type": "base64", "media_type": .string(media), "data": .string(data)]
            case .url(let url):
                source = ["type": "url", "url": .string(url)]
            case .unknown(let raw):
                source = raw
            }
            return ["type": "image", "source": source]
        case .serverToolUse(let block):
            return [
                "type": "server_tool_use", "id": .string(block.id), "name": .string(block.name), "input": block.input,
            ]
        case .advisorToolResult(let block):
            // TODO(fill A): the content's wire form.
            return ["type": "advisor_tool_result", "tool_use_id": .string(block.toolUseID)]
        case .unknown(_, let raw):
            return raw
        }
    }
}
