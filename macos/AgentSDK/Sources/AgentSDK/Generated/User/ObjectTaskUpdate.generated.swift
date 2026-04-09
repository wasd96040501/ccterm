import Foundation

public struct ObjectTaskUpdate: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let error: String?
    public let statusChange: StatusChange?
    public let success: Bool?
    public let taskId: String?
    public let updatedFields: [String]?
    public let verificationNudgeNeeded: Bool?
}
