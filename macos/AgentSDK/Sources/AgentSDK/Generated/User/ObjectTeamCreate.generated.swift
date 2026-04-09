import Foundation

public struct ObjectTeamCreate: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let leadAgentId: String?
    public let teamFilePath: String?
    public let teamName: String?
}
