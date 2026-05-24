import Foundation

public struct StreamMessageStart: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let message: [String: Any]?
}
