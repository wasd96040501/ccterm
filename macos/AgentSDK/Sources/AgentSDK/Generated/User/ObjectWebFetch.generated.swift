import Foundation

public struct ObjectWebFetch: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let bytes: Int?
    public let code: Int?
    public let codeText: String?
    public let durationMs: Int?
    public let result: String?
    public let url: String?
}
