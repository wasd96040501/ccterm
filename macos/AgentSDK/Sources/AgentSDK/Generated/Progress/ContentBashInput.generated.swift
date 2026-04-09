import Foundation

public struct ContentBashInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let command: String?
    public let context: Int?
    public let description: String?
    public let outputMode: String?
    public let path: String?
    public let pattern: String?
    public let timeout: Int?
}
