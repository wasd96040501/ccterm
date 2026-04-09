import Foundation

public struct Thinking: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let signature: String?
    public let thinking: String?
}
