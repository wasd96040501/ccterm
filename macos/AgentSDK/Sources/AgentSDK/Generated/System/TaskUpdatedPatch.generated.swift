import Foundation

public struct TaskUpdatedPatch: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let endTime: Double?
    public let outputFile: String?
    public let status: String?
    public let summary: String?
}
