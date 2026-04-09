import Foundation

public struct SystemStatus: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let permissionMode: String?
    public let sessionId: String?
    public let status: Any?
    public let uuid: String?
}
