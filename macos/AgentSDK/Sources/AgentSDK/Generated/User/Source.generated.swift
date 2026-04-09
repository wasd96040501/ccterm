import Foundation

public struct Source: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let data: String?
    public let mediaType: String?
    public let `type`: String?
}
