import Foundation

public struct TurnDuration: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let cwd: String?
    public let durationMs: Int?
    public let entrypoint: String?
    public let forkedFrom: ForkedFrom?
    public let gitBranch: String?
    public let isMeta: Bool?
    public let isSidechain: Bool?
    public let messageCount: Int?
    public let parentUuid: String?
    public let sessionId: String?
    public let slug: String?
    public let teamName: String?
    public let timestamp: String?
    public let userType: String?
    public let uuid: String?
    public let version: String?
}
