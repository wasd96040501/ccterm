import Foundation

/// Token counts for one API call or one turn.
public struct Usage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationInputTokens: Int
    public var cacheReadInputTokens: Int

    public init(
        inputTokens: Int = 0, outputTokens: Int = 0, cacheCreationInputTokens: Int = 0,
        cacheReadInputTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }

    /// Everything that counted toward the context window.
    public var totalInputTokens: Int { inputTokens + cacheCreationInputTokens + cacheReadInputTokens }
}

extension Usage: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.inputTokens = c.lenient(Int.self, "input_tokens") ?? 0
        self.outputTokens = c.lenient(Int.self, "output_tokens") ?? 0
        self.cacheCreationInputTokens = c.lenient(Int.self, "cache_creation_input_tokens") ?? 0
        self.cacheReadInputTokens = c.lenient(Int.self, "cache_read_input_tokens") ?? 0
    }
}
