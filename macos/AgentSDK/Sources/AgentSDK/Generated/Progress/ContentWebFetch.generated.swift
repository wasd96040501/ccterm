import Foundation

public struct ContentWebFetch: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let caller: Caller?
    public let id: String?
    public let input: ContentWebFetchInput?
    public let `type`: String?
}
