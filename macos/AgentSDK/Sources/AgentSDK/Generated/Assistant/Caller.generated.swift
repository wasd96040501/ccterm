import Foundation

public struct Caller: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let `type`: String?
}
