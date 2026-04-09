import Foundation

public struct ToolUseExitPlanModeInput: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let allowedPrompts: [AllowedPrompts]?
    public let plan: String?
    public let planFilePath: String?
}
