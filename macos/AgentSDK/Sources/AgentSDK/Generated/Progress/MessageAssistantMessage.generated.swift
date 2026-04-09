import Foundation

public struct MessageAssistantMessage: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let content: [MessageAssistantMessageContent]?
    public let contextManagement: Any?
    public let id: String?
    public let model: String?
    public let role: String?
    public let stopReason: String?
    public let stopSequence: Any?
    public let `type`: String?
    public let usage: AssistantUsage?
}
