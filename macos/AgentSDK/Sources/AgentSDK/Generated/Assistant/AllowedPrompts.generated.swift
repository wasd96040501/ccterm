import Foundation

public struct AllowedPrompts: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let prompt: String?
    public let tool: String?
}
