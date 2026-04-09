import Foundation

public struct ObjectSkill: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let allowedTools: [String]?
    public let commandName: String?
    public let success: Bool?
}
