import Foundation

public struct MessageUserMessage: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let content: [MessageUserMessageContent]?
    public let role: String?
}
