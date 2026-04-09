import Foundation

public struct ToolUseEditInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let filePath: String?
    public let newString: String?
    public let oldString: String?
    public let replaceAll: Bool?
}
