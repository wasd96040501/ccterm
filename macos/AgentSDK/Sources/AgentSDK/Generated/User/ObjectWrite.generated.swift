import Foundation

public struct ObjectWrite: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let content: String?
    public let filePath: String?
    public let originalFile: String?
    public let structuredPatch: [StructuredPatch]?
    public let `type`: String?
}
