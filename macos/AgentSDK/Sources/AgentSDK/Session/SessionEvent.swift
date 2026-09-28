import Foundation

/// Everything a ``Session`` reports, in the order the CLI produced it.
public enum SessionEvent: Sendable {
    case message(Message)
    /// A tool call needs approval; answer with ``PermissionRequest/respond(_:)``.
    case permissionRequest(PermissionRequest)
    /// The CLI withdrew the request with this ``PermissionRequest/id``;
    /// dismiss any UI showing it.
    case permissionRequestCancelled(id: String)
    /// The CLI process ended. Always the last event; the stream finishes
    /// right after it.
    case exited(Termination)
}

/// How the CLI process ended.
public struct Termination: Sendable, Equatable {
    public var exitCode: Int32
    /// The tail of the process's standard error, for diagnostics.
    public var stderr: String

    public init(exitCode: Int32, stderr: String) {
        self.exitCode = exitCode
        self.stderr = stderr
    }
}
