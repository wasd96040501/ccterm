import Foundation

public struct CacheCreation: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let ephemeral1hInputTokens: Int?
    public let ephemeral5mInputTokens: Int?
}
