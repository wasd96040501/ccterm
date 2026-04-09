import Foundation

public struct Dequeue: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let sessionId: String?
    public let timestamp: String?
}
