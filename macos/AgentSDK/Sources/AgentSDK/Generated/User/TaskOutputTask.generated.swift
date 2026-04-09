import Foundation

public struct TaskOutputTask: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let description: String?
    public let exitCode: Int?
    public let output: String?
    public let status: String?
    public let taskId: String?
    public let taskType: String?
}
