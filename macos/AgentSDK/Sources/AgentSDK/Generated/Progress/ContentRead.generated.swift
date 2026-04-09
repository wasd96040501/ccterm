import Foundation

public struct ContentRead: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let caller: Caller?
    public let id: String?
    public let input: ContentReadInput?
    public let `type`: String?
}
