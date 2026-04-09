import Foundation

public struct Enqueue: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let content: String?
    public let sessionId: String?
    public let timestamp: String?
}
