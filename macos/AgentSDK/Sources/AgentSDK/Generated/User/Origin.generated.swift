import Foundation

public struct Origin: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let kind: String?
}
