import Foundation

public struct SendMessageInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let approve: Bool?
    public let content: String?
    public let message: InputMessage?
    public let recipient: String?
    public let requestId: String?
    public let summary: String?
    public let to: String?
    public let `type`: String?
}
