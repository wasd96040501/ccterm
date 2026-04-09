import Foundation

public struct ObjectGrep: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let appliedLimit: Int?
    public let appliedOffset: Int?
    public let content: String?
    public let filenames: [String]?
    public let mode: String?
    public let numFiles: Int?
    public let numLines: Int?
    public let numMatches: Int?
}
