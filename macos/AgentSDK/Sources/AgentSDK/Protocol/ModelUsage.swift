import Foundation

/// Cumulative usage of one model over the session.
public struct ModelUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadInputTokens: Int
    public var cacheCreationInputTokens: Int
    public var webSearchRequests: Int
    public var costUSD: Double
    public var contextWindow: Int
    public var maxOutputTokens: Int
}

extension ModelUsage: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.inputTokens = c.lenient(Int.self, "inputTokens") ?? 0
        self.outputTokens = c.lenient(Int.self, "outputTokens") ?? 0
        self.cacheReadInputTokens = c.lenient(Int.self, "cacheReadInputTokens") ?? 0
        self.cacheCreationInputTokens = c.lenient(Int.self, "cacheCreationInputTokens") ?? 0
        self.webSearchRequests = c.lenient(Int.self, "webSearchRequests") ?? 0
        self.costUSD = c.lenient(Double.self, "costUSD") ?? 0
        self.contextWindow = c.lenient(Int.self, "contextWindow") ?? 0
        self.maxOutputTokens = c.lenient(Int.self, "maxOutputTokens") ?? 0
    }
}
