import Foundation

/// How the session's system prompt is built. See
/// ``SessionConfiguration/systemPrompt``.
public enum SystemPromptConfig: Sendable {
    /// Replace the default prompt.
    case custom(String)
    /// Keep the default prompt and append to it.
    case append(String)
    /// No system prompt at all.
    case empty
}
