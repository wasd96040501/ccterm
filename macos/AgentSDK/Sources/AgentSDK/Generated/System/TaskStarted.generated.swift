import Foundation

public struct TaskStarted: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let description: String?
    public let prompt: String?
    public let sessionId: String?
    public let taskId: String?
    public let taskType: String?
    public let toolUseId: String?
    public let uuid: String?
}
