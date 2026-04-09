import Foundation

public struct Text: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let text: String?
}
