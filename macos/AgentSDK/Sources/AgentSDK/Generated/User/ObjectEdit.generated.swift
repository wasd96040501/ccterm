import Foundation

public struct ObjectEdit: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let filePath: String?
    public let newString: String?
    public let oldString: String?
    public let originalFile: String?
    public let replaceAll: Bool?
    public let structuredPatch: [StructuredPatch]?
    public let userModified: Bool?
}
