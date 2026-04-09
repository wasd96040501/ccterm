import Foundation

public struct ResultsObject: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let content: [ObjectContent]?
    public let toolUseId: String?
}
