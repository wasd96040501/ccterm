import Foundation

public struct Plugins: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let name: String?
    public let path: String?
}
