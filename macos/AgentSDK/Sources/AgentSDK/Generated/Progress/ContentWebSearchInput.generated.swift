import Foundation

public struct ContentWebSearchInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let allowedDomains: [String]?
    public let query: String?
}
