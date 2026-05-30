import Foundation

public struct StreamContentBlockStart: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let contentBlock: [String: Any]?
    public let index: Int?
}
