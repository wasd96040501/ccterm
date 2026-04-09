import Foundation

public struct Message2UserMessage: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let content: Message2UserMessageContent?
    public let role: String?
}
