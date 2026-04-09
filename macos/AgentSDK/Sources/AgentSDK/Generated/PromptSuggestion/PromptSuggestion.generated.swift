import Foundation

public struct PromptSuggestion: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let sessionId: String?
    public let suggestion: String?
    public let uuid: String?
}
