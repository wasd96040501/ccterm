import Foundation

public struct Message2AssistantMessage: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let container: Any?
    public let content: [Message2AssistantMessageContent]?
    public let contextManagement: ContextManagement?
    public let id: String?
    public let model: String?
    public let role: String?
    public let stopReason: String?
    public let stopSequence: String?
    public let `type`: String?
    public let usage: MessageUsage?
}
