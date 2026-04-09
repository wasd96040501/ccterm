import Foundation

public struct AnnotationsValue: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let notes: String?
    public let preview: String?
}
