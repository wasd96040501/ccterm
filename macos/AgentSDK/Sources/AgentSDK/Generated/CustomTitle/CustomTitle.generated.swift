import Foundation

public struct CustomTitle: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let customTitle: String?
    public let sessionId: String?
}
