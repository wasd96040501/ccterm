import Foundation

public struct ContentWebSearch: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let caller: Caller?
    public let id: String?
    public let input: ContentWebSearchInput?
    public let `type`: String?
}
