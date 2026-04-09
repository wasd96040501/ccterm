import Foundation

public struct ContentGrepInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let A: Int?
    public let C: Int?
    public let I: Bool?
    public let N: Bool?
    public let context: Int?
    public let glob: String?
    public let headLimit: Int?
    public let outputMode: String?
    public let path: String?
    public let pattern: String?
    public let `type`: String?
}
