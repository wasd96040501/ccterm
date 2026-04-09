import Foundation

public struct TaskCreateTask: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let id: String?
    public let subject: String?
}
