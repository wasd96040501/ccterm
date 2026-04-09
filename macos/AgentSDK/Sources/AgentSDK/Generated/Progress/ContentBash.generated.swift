import Foundation

public struct ContentBash: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let caller: Caller?
    public let id: String?
    public let input: ContentBashInput?
    public let `type`: String?
}
