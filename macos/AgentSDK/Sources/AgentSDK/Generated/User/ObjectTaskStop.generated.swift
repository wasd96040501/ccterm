import Foundation

public struct ObjectTaskStop: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let command: String?
    public let message: String?
    public let taskId: String?
    public let taskType: String?
}
