import Foundation

public struct ObjectContent: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let title: String?
    public let url: String?
}
