import Foundation

public struct ObjectGlob: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let durationMs: Int?
    public let filenames: [String]?
    public let numFiles: Int?
    public let truncated: Bool?
}
