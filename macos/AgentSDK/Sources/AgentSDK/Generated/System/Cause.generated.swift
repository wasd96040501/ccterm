import Foundation

public struct Cause: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let code: String?
    public let errno: Int?
    public let path: String?
}
