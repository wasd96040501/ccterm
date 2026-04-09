import Foundation

public struct ToolUseReadInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let filePath: String?
    public let limit: Limit?
    public let offset: ToolUseReadInputOffset?
}
