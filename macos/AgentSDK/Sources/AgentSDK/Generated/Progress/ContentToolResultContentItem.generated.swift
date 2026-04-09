import Foundation

public struct ContentToolResultContentItem: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let toolName: String?
    public let `type`: String?
}
