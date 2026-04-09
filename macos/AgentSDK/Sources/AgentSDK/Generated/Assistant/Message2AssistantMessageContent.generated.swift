import Foundation

public enum Message2AssistantMessageContent: JSONParseable, UnknownStrippable {
    case text(Text)
    case thinking(Thinking)
    case toolUse(ToolUse)
    case unknown(name: String, raw: [String: Any])
}
