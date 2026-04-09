import Foundation

public struct MessageAssistant: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let message: MessageAssistantMessage?
    public let requestId: String?
    public let timestamp: String?
    public let uuid: String?
}
