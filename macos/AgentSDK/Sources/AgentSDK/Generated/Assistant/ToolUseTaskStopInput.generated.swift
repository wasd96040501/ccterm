import Foundation

public struct ToolUseTaskStopInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let taskId: String?
}
