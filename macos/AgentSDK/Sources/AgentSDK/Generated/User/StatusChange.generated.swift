import Foundation

public struct StatusChange: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let from: String?
    public let to: String?
}
