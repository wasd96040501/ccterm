import Foundation

public struct Snapshot: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let messageId: String?
    public let timestamp: String?
    public let trackedFileBackups: [String: TrackedFileBackupsValue]?
}
