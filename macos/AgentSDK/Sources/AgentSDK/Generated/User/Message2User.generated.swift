import Foundation

public struct Message2User: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let agentId: String?
    public let cwd: String?
    public let entrypoint: String?
    public let forkedFrom: ForkedFrom?
    public let gitBranch: String?
    public let imagePasteIds: [Int]?
    public let isCompactSummary: Bool?
    public let isMeta: Bool?
    public let isSidechain: Bool?
    public let isSynthetic: Bool?
    public let isVisibleInTranscriptOnly: Bool?
    public let message: Message2UserMessage?
    public let origin: Origin?
    public let parentToolUseId: String?
    public let parentUuid: String?
    public let permissionMode: String?
    public let planContent: String?
    public let promptId: String?
    public let sessionId: String?
    public let slug: String?
    public let sourceToolAssistantUuid: String?
    public let sourceToolUseId: String?
    public let teamName: String?
    public let timestamp: String?
    public let todos: [Any]?
    public var toolUseResult: ToolUseResult?
    public let userType: String?
    public let uuid: String?
    public let version: String?
}
