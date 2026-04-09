import Foundation

public struct LocalCommand: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let agentId: String?
    public let content: String?
    public let cwd: String?
    public let entrypoint: String?
    public let forkedFrom: ForkedFrom?
    public let gitBranch: String?
    public let isMeta: Bool?
    public let isSidechain: Bool?
    public let level: String?
    public let parentUuid: String?
    public let sessionId: String?
    public let slug: String?
    public let teamName: String?
    public let timestamp: String?
    public let userType: String?
    public let uuid: String?
    public let version: String?
}
