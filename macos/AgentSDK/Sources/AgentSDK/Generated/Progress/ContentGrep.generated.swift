import Foundation

public struct ContentGrep: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let caller: Caller?
    public let id: String?
    public let input: ContentGrepInput?
    public let `type`: String?
}
