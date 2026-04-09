import Foundation

public enum ItemToolResultContentItem: JSONParseable, UnknownStrippable {
    case image(Image)
    case text(Text)
    case toolReference(ToolReference)
    case unknown(name: String, raw: [String: Any])
}
