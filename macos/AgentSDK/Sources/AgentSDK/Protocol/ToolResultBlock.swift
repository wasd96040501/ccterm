import Foundation

/// The result of a tool call, as the model sees it.
///
/// This is the model-facing rendering (prose, `cat -n` text, images). For the
/// tool's structured output use ``UserMessage/toolUseResult`` or
/// ``UserMessage/toolOutcome(_:)``.
public struct ToolResultBlock: Sendable, Equatable {
    public var toolUseID: String
    /// Text or blocks; a bare string is normalized to one `.text` block.
    public var content: [ContentBlock]
    public var isError: Bool

    public init(toolUseID: String, content: [ContentBlock], isError: Bool = false) {
        self.toolUseID = toolUseID
        self.content = content
        self.isError = isError
    }
}
