import Foundation

public struct ToolUseTaskUpdateInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let activeForm: String?
    public let addBlockedBy: [String]?
    public let description: String?
    public let owner: String?
    public let status: String?
    public let taskId: String?
}
