import Foundation

/// `claude -p --output-format json` 的返回结果。
public struct PromptResult {
    /// 模型文本回复（result 字段）。
    public let result: String

    /// 结构化输出（仅配置了 jsonSchema 时有值）。
    public let structuredOutput: [String: Any]?

    /// Session ID。
    public let sessionId: String?

    /// 总花费（美元）。
    public let totalCostUsd: Double?

    /// 耗时（毫秒）。
    public let durationMs: Int?

    /// 原始 JSON 字典（需要其他字段时自取）。
    public let raw: [String: Any]
}
