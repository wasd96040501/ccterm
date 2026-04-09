import Foundation

public struct ToolUseSendMessage: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let caller: Caller?
    public let id: String?
    public let input: SendMessageInput?
}
