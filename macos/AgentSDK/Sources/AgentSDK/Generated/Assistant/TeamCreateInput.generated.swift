import Foundation

public struct TeamCreateInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let agentType: String?
    public let description: String?
    public let teamName: String?
}
