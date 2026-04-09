import Foundation

public struct ToolUseTaskOutputInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let block: Bool?
    public let taskId: String?
    public let timeout: Int?
}
