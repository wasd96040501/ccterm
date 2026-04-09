import Foundation

public enum MessageContentItem: JSONParseable, UnknownStrippable {
    case image(Image)
    case text(Text)
    case toolResult(ItemToolResult)
    case unknown(name: String, raw: [String: Any])
}
