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

extension PermissionRule: SettingsValue {
    /// Parses the rule string settings use: `Bash(git status:*)` or a bare
    /// tool name. `Tool()` and `Tool(*)` mean the whole tool.
    public init?(settingsJSON json: JSONValue) {
        guard let rule = json.stringValue, !rule.isEmpty else { return nil }
        guard rule.hasSuffix(")"), let open = rule.firstIndex(of: "("), open != rule.startIndex else {
            self.init(toolName: rule)
            return
        }
        let content = String(rule[rule.index(after: open)..<rule.index(before: rule.endIndex)])
        let unescaped =
            content
            .replacingOccurrences(of: "\\(", with: "(")
            .replacingOccurrences(of: "\\)", with: ")")
            .replacingOccurrences(of: "\\\\", with: "\\")
        self.init(
            toolName: String(rule[..<open]),
            ruleContent: unescaped.isEmpty || unescaped == "*" ? nil : unescaped)
    }

    /// The rule string settings use, with parentheses and backslashes in the
    /// content escaped as the CLI writes them.
    public var settingsJSON: JSONValue {
        guard let ruleContent, !ruleContent.isEmpty else { return .string(toolName) }
        let escaped =
            ruleContent
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
        return .string("\(toolName)(\(escaped))")
    }
}
