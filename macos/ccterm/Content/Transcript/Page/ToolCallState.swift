import Foundation

/// Where a tool call is in its life.
///
/// A transcript read from disk yields only the settled states — `done`,
/// `failed`, `denied`, `interrupted`, `background` — and `running` for a call
/// at the very end of a file still being written. The live ones (`preparing`,
/// `waiting`, and `running` elsewhere) are here because every view draws them
/// (design/transcript/01-run.md "Live"); nothing feeds them until the app
/// runs a session.
nonisolated enum ToolCallState: Sendable, Equatable {
    /// Its input is still streaming in.
    case preparing
    /// Stopped on a permission request, with the reason the CLI gave.
    case waiting(reason: String?)
    case running
    /// Launched into the background; its news arrives later.
    case background
    case done
    /// The tool reported an error; the CLI's message.
    case failed(message: String)
    /// The reader, or a permission rule, said no. The call did nothing.
    case denied
    /// Stopped by the reader while it ran.
    case interrupted

    /// Whether the call is still going — nothing about it is final.
    var isLive: Bool {
        switch self {
        case .preparing, .waiting, .running, .background: true
        case .done, .failed, .denied, .interrupted: false
        }
    }
}
