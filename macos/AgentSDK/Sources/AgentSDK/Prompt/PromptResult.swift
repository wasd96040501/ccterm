import Foundation

/// Return value of `claude -p --output-format json`.
public struct PromptResult {
    /// Model text reply (the `result` field).
    public let result: String

    /// Structured output (populated only when `jsonSchema` was configured).
    public let structuredOutput: [String: Any]?

    public let sessionId: String?

    /// Total cost in USD.
    public let totalCostUsd: Double?

    /// Duration in milliseconds.
    public let durationMs: Int?

    /// Raw JSON dictionary — read directly when you need a field that is not surfaced above.
    public let raw: [String: Any]
}
