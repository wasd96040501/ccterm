import Foundation

/// A built-in tool's name and the shapes of its input and structured output.
///
/// Messages carry tool data untyped (``ToolUseBlock/input``,
/// ``UserMessage/toolUseResult``) because the shape depends on the tool
/// name. A definition in ``Tools`` reads them typed:
///
/// ```swift
/// if let bash = toolUse.input(as: Tools.Bash.self) { print(bash.command) }
/// switch resultMessage.toolOutcome(Tools.Bash.self) {
/// case .success(let output)?: print(output.stdout)
/// case .failure(let message)?: print(message)
/// case .unavailable?, nil: break
/// }
/// ```
///
/// Decoding is lenient: unknown fields are ignored, and a field of the wrong
/// type reads as absent.
public protocol ToolDefinition {
    associatedtype Input: Decodable & Sendable
    associatedtype Output: Decodable & Sendable

    /// The tool name the CLI records.
    static var name: String { get }
    /// Older or alternative names for the same tool.
    static var aliases: [String] { get }
}

extension ToolDefinition {
    public static var aliases: [String] { [] }

    /// Whether `name` refers to this tool.
    public static func matches(_ name: String) -> Bool {
        name == Self.name || aliases.contains(name)
    }
}

extension ToolUseBlock {
    /// The input typed as `tool`'s; `nil` when this call is to another tool
    /// or the input does not fit.
    public func input<T: ToolDefinition>(as tool: T.Type) -> T.Input? {
        guard T.matches(name) else { return nil }
        return try? input.decode(T.Input.self)
    }
}

extension UserMessage {
    /// How the tool call answered by this message went, reading its output
    /// as `tool`'s. `nil` when the message carries no tool result.
    ///
    /// The caller supplies the tool: a result names only its
    /// ``ToolResultBlock/toolUseID``, so match it to the ``ToolUseBlock``
    /// first.
    public func toolOutcome<T: ToolDefinition>(_ tool: T.Type) -> ToolOutcome<T.Output>? {
        guard let result = toolResult else { return nil }
        if result.isError || toolUseResult?.stringValue != nil {
            let text = toolUseResult?.stringValue ?? result.content.compactMap(\.text).joined(separator: "\n")
            return .failure(text)
        }
        guard let raw = toolUseResult, let output = try? raw.decode(T.Output.self) else { return .unavailable }
        return .success(output)
    }
}
