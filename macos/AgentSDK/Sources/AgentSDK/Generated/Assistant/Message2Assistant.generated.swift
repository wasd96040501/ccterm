import Foundation

public struct Message2Assistant: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let agentId: String?
    public let cwd: String?
    public let entrypoint: String?
    public let error: String?
    public let forkedFrom: ForkedFrom?
    public let gitBranch: String?
    public let isApiErrorMessage: Bool?
    public let isSidechain: Bool?
    public let line: Int?
    public let message: Message2AssistantMessage?
    public let parentToolUseId: String?
    public let parentUuid: String?
    public let requestId: String?
    public let sessionId: String?
    public let slug: String?
    public let teamName: String?
    public let timestamp: String?
    public let usage: AssistantUsage?
    public let userType: String?
    public let uuid: String?
    public let version: String?
}
