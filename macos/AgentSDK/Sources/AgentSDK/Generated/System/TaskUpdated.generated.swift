import Foundation

public struct TaskUpdated: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let patch: TaskUpdatedPatch?
    public let sessionId: String?
    public let taskId: String?
    public let toolUseId: String?
    public let uuid: String?
}
