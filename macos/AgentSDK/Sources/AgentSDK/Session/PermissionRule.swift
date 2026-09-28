import Foundation

/// A permission rule: a tool, optionally narrowed by a pattern
/// (`Bash(git status:*)` is `toolName: "Bash", ruleContent: "git status:*"`).
public struct PermissionRule: Sendable, Equatable, Codable {
    public var toolName: String
    public var ruleContent: String?

    public init(toolName: String, ruleContent: String? = nil) {
        self.toolName = toolName
        self.ruleContent = ruleContent
    }
}
