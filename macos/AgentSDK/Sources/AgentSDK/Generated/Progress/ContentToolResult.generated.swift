import Foundation

public struct ContentToolResult: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let content: ContentToolResultContent?
    public let isError: Bool?
    public let toolUseId: String?
}
