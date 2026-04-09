import Foundation

public struct ObjectExitPlanMode: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let filePath: String?
    public let isAgent: Bool?
    public let plan: String?
}
