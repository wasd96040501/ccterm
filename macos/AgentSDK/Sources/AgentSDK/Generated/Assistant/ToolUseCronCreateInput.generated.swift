import Foundation

public struct ToolUseCronCreateInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let cron: String?
    public let prompt: String?
    public let recurring: Bool?
}
