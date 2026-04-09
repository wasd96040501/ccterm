import Foundation

public struct ToolUseWriteInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let content: String?
    public let filePath: String?
}
