import Foundation

public struct StreamContentBlockStop: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let index: Int?
}
