import Foundation

public struct AssistantUsage: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let cacheCreation: CacheCreation?
    public let cacheCreationInputTokens: Int?
    public let cacheReadInputTokens: Int?
    public let inferenceGeo: String?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let serviceTier: String?
}
