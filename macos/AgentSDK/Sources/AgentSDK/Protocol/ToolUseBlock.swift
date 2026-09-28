import Foundation

/// A tool call made by the model.
public struct ToolUseBlock: Sendable, Equatable {
    public var id: String
    /// Tool name as the CLI recorded it: a built-in (`Bash`, `Read`, …), an
    /// MCP tool (`mcp__server__tool`), or anything the model invented.
    public var name: String
    /// The call's input. Untyped because the shape depends on ``name``; read a
    /// built-in tool's input with ``input(as:)``.
    public var input: JSONValue

    public init(id: String, name: String, input: JSONValue) {
        self.id = id
        self.name = name
        self.input = input
    }
}
