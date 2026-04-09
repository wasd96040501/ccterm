import Foundation

public struct BashProgress: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let elapsedTimeSeconds: Int?
    public let fullOutput: String?
    public let output: String?
    public let taskId: String?
    public let timeoutMs: Int?
    public let totalBytes: Int?
    public let totalLines: Int?
}
