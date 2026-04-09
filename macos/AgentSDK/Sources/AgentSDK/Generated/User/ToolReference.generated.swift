import Foundation

public struct ToolReference: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let toolName: String?
}
