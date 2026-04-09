import Foundation

public struct MessageObject: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let approve: Bool?
    public let reason: String?
    public let requestId: String?
    public let `type`: String?
}
