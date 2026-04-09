import Foundation

public struct MessageUser: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let message: MessageUserMessage?
    public let timestamp: String?
    public let toolUseResult: String?
    public let uuid: String?
}
