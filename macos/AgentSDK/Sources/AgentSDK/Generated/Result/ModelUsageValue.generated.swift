import Foundation

public struct ModelUsageValue: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let cacheCreationInputTokens: Int?
    public let cacheReadInputTokens: Int?
    public let contextWindow: Int?
    public let costUsd: Double?
    public let inputTokens: Int?
    public let maxOutputTokens: Int?
    public let outputTokens: Int?
    public let webSearchRequests: Int?
}
