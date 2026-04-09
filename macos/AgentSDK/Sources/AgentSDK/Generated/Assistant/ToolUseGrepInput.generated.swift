import Foundation

public struct ToolUseGrepInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let A: Int?
    public let B: Int?
    public let C: Int?
    public let I: Bool?
    public let N: Bool?
    public let context: Int?
    public let filePath: String?
    public let glob: String?
    public let headLimit: Int?
    public let limit: Int?
    public let offset: Int?
    public let outputMode: String?
    public let path: String?
    public let pattern: String?
    public let query: String?
    public let `type`: String?
}
