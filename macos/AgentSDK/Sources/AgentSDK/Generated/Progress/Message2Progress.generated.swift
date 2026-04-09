import Foundation

public struct Message2Progress: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let agentId: String?
    public let cwd: String?
    public let data: ProgressData?
    public let entrypoint: String?
    public let forkedFrom: ForkedFrom?
    public let gitBranch: String?
    public let isSidechain: Bool?
    public let parentToolUseId: String?
    public let parentUuid: String?
    public let sessionId: String?
    public let slug: String?
    public let teamName: String?
    public let timestamp: String?
    public let toolUseId: String?
    public let userType: String?
    public let uuid: String?
    public let version: String?
}
