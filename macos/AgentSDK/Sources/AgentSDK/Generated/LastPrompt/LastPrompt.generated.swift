import Foundation

public struct LastPrompt: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let lastPrompt: String?
    public let sessionId: String?
}
