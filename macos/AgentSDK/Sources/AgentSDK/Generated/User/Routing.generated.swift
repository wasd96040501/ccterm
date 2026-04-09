import Foundation

public struct Routing: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let content: String?
    public let sender: String?
    public let senderColor: String?
    public let summary: String?
    public let target: String?
    public let targetColor: String?
}
