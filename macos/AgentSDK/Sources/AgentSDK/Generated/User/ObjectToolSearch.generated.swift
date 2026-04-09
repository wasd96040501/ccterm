import Foundation

public struct ObjectToolSearch: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let matches: [String]?
    public let query: String?
    public let totalDeferredTools: Int?
}
