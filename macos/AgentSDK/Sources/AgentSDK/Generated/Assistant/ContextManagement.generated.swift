import Foundation

public struct ContextManagement: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let appliedEdits: [Any]?
}
