import Foundation

public struct MessageUsageServerToolUse: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let webFetchRequests: Int?
    public let webSearchRequests: Int?
}
