import Foundation

public struct ContentToolSearch: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let caller: Caller?
    public let id: String?
    public let input: ToolUseToolSearchInput?
    public let `type`: String?
}
