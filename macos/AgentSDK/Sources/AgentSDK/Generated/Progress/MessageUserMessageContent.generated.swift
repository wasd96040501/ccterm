import Foundation

public enum MessageUserMessageContent: JSONParseable, UnknownStrippable {
    case text(Text)
    case toolResult(ContentToolResult)
    case unknown(name: String, raw: [String: Any])
}
