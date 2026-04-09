import Foundation

public struct ToolUseToolSearchInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let maxResults: Int?
    public let query: String?
}
