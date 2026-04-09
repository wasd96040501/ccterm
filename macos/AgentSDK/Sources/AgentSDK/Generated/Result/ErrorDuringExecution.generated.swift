import Foundation

public struct ErrorDuringExecution: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let durationApiMs: Int?
    public let durationMs: Int?
    public let errors: [String]?
    public let fastModeState: String?
    public let isError: Bool?
    public let modelUsage: [String: ModelUsageValue]?
    public let numTurns: Int?
    public let permissionDenials: [ErrorDuringExecutionPermissionDenials]?
    public let sessionId: String?
    public let stopReason: String?
    public let totalCostUsd: Double?
    public let usage: ErrorDuringExecutionUsage?
    public let uuid: String?
}
