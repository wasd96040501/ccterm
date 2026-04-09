import Foundation

public struct AgentProgress: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let agentId: String?
    public let message: AgentProgressMessage?
    public let normalizedMessages: [Any]?
    public let prompt: String?
    public let resume: String?
}
