import Foundation

public struct ToolUseTaskCreateInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let activeForm: String?
    public let description: String?
    public let subject: String?
}
