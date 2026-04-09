import Foundation

public struct ForkedFrom: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let messageUuid: String?
    public let sessionId: String?
}
