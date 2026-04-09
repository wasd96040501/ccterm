import Foundation

public struct ObjectTaskCreate: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let task: TaskCreateTask?
}
