import Foundation

public struct TaskNotificationUsage: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let durationMs: Int?
    public let toolUses: Int?
    public let totalTokens: Int?
}
