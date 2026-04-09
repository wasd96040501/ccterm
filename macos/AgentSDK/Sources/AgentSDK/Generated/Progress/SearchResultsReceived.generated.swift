import Foundation

public struct SearchResultsReceived: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let query: String?
    public let resultCount: Int?
}
