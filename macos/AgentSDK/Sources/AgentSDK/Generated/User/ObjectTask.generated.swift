import Foundation

public struct ObjectTask: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let agentId: String?
    public let canReadOutputFile: Bool?
    public let content: [TaskContent]?
    public let description: String?
    public let isAsync: Bool?
    public let outputFile: String?
    public let prompt: String?
    public let status: String?
    public let totalDurationMs: Int?
    public let totalTokens: Int?
    public let totalToolUseCount: Int?
    public let usage: ObjectTaskUsage?
}
