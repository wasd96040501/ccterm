import Foundation

public struct TrackedFileBackupsValue: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let backupFileName: String?
    public let backupTime: String?
    public let version: Int?
}
