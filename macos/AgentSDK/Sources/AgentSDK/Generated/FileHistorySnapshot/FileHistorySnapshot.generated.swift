import Foundation

public struct FileHistorySnapshot: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let isSnapshotUpdate: Bool?
    public let messageId: String?
    public let snapshot: Snapshot?
}
