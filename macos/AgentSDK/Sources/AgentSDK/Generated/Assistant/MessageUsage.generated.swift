import Foundation

public struct MessageUsage: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let cacheCreation: CacheCreation?
    public let cacheCreationInputTokens: Int?
    public let cacheReadInputTokens: Int?
    public let inferenceGeo: String?
    public let inputTokens: Int?
    public let iterations: [Any]?
    public let outputTokens: Int?
    public let serverToolUse: MessageUsageServerToolUse?
    public let serviceTier: String?
    public let speed: String?
}
