import Foundation

public struct ObjectTaskOutput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let retrievalStatus: String?
    public let task: TaskOutputTask?
}
