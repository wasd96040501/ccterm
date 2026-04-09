import Foundation

public struct QueryUpdate: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let query: String?
}
