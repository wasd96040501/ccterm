import Foundation

public struct WaitingForTask: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let taskDescription: String?
    public let taskType: String?
}
