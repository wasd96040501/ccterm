import Foundation

public struct ToolUseWebSearchInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let allowedDomains: [String]?
    public let query: String?
    public let searchQuery: String?
}
