import Foundation

public struct McpServers: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let name: String?
    public let status: String?
}
