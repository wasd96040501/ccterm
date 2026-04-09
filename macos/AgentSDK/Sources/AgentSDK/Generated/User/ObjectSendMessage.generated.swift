import Foundation

public struct ObjectSendMessage: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let message: String?
    public let requestId: String?
    public let routing: Routing?
    public let success: Bool?
    public let target: String?
}
