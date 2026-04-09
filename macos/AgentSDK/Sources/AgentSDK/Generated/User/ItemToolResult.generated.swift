import Foundation

public struct ItemToolResult: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let content: ItemToolResultContent?
    public let isError: Bool?
    public let toolUseId: String?
}
