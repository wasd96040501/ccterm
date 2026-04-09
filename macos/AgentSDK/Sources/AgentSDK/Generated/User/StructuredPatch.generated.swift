import Foundation

public struct StructuredPatch: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let lines: [String]?
    public let newLines: Int?
    public let newStart: Int?
    public let oldLines: Int?
    public let oldStart: Int?
}
