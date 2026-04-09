import Foundation

public struct TaskContent: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let text: String?
    public let `type`: String?
}
