import Foundation

public struct TaskNotification: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let outputFile: String?
    public let sessionId: String?
    public let status: String?
    public let summary: String?
    public let taskId: String?
    public let toolUseId: String?
    public let usage: TaskNotificationUsage?
    public let uuid: String?
}
