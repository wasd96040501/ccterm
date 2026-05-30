import Foundation

public struct ThinkingTokens: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    /// Cumulative running estimate of thinking tokens for the current thinking
    /// block (resets per block). Monotonic. Approximate progress for
    /// spinners/pills — NOT the authoritative count (that lands in the turn's
    /// `message_delta` / `.result` usage).
    public let estimatedTokens: Int?
    /// The per-frame increment carried by the originating `thinking_delta`
    /// (`estimated_tokens` on the raw stream event). `estimatedTokens` is the
    /// running sum of these.
    public let estimatedTokensDelta: Int?
    public let sessionId: String?
    public let uuid: String?
}
