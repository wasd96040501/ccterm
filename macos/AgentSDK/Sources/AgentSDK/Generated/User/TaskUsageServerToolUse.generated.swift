import Foundation

public struct TaskUsageServerToolUse: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let webFetchRequests: Int?
    public let webSearchRequests: Int?
}
