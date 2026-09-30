import AgentSDK
import Foundation

/// Whether a launch works: what `--version` said, or why it didn't.
nonisolated enum LaunchCheck: Equatable, Sendable {
    /// The CLI ran and reported this version.
    case valid(CLIVersion)
    /// It didn't; a short reason, ready to show.
    case invalid(String)
}
