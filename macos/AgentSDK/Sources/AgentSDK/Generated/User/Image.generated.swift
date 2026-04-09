import Foundation

public struct Image: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let source: Source?
}
