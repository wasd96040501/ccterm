import Foundation

public struct ContentWebFetchInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let prompt: String?
    public let url: String?
}
