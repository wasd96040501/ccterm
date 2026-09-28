import Foundation

/// The base tool set. See ``SessionConfiguration/tools``.
public enum ToolsConfig: Sendable {
    /// Exactly these tools; empty means none.
    case list([String])
    /// The CLI's default set.
    case `default`
}
