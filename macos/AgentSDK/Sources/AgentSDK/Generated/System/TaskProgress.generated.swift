import Foundation

public struct TaskProgress: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let description: String?
    public let lastToolName: String?
    public let sessionId: String?
    public let taskId: String?
    public let toolUseId: String?
    public let usage: TaskNotificationUsage?
    public let uuid: String?
}
