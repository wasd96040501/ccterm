import Foundation

public struct StreamContentBlockDelta: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let delta: [String: Any]?
    public let index: Int?
}
