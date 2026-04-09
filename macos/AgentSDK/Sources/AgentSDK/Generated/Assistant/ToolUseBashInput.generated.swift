import Foundation

public struct ToolUseBashInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let command: String?
    public let context: Int?
    public let description: String?
    public let outputMode: String?
    public let path: String?
    public let pattern: String?
    public let runInBackground: Bool?
    public let timeout: Int?
}
