import Foundation

public struct MicrocompactBoundary: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let content: String?
    public let cwd: String?
    public let gitBranch: String?
    public let isMeta: Bool?
    public let isSidechain: Bool?
    public let level: String?
    public let microcompactMetadata: MicrocompactBoundaryMicrocompactMetadata?
    public let parentUuid: String?
    public let sessionId: String?
    public let slug: String?
    public let timestamp: String?
    public let userType: String?
    public let uuid: String?
    public let version: String?
}
