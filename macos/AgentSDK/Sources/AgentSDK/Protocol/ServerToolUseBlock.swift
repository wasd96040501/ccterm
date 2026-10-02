import Foundation

/// A call to a tool the API runs itself rather than the CLI (`server_tool_use`):
/// the advisor (`name == "advisor"`, empty input). Its result is in the same
/// assistant message, never in a user message's tool result.
public struct ServerToolUseBlock: Sendable, Equatable {
    public var id: String
    public var name: String
    public var input: JSONValue

    public init(id: String, name: String, input: JSONValue = .object([:])) {
        self.id = id
        self.name = name
        self.input = input
    }
}
