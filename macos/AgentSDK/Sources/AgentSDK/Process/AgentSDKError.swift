import Foundation

/// Errors thrown by the SDK. Task cancellation surfaces as `CancellationError`.
public enum AgentSDKError: Error, LocalizedError, Sendable, Equatable {
    /// No `claude` binary was found; set ``SessionConfiguration/binaryPath``.
    case binaryNotFound
    /// The CLI process could not be launched.
    case launchFailed(String)
    /// ``Session/start()`` was called more than once.
    case alreadyStarted
    /// The session has not started, or its process has already exited.
    case notRunning
    /// The CLI process exited while a request was outstanding.
    case processExited(Termination)
    /// The CLI answered a control request with an error. `code` is the
    /// response's `error_code` when it gave one (see ``refusalCode``).
    case controlRequestFailed(subtype: String, message: String, code: String? = nil)
    /// The CLI's answer to a control request did not have the expected shape.
    case invalidResponse(subtype: String)
    /// A one-shot ``Prompt`` run failed.
    case promptFailed(exitCode: Int32, stderr: String)
    /// A `claude auth` command failed.
    case authFailed(exitCode: Int32, stderr: String)
    /// `claude --version` failed or timed out; `message` is stderr's last line.
    case versionFailed(exitCode: Int32, message: String)
    /// `claude --version` ran but printed no version.
    case noVersion(output: String)

    /// For a control request the CLI refused: its `error_code`
    /// (`restricted_by_org`, `bypass_not_launched`, …), so a host can say why
    /// in its own words. `nil` for any other error, or a refusal without one.
    public var refusalCode: String? {
        if case .controlRequestFailed(_, _, let code) = self { return code }
        return nil
    }

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "CLI binary not found. Install it or set binaryPath in configuration."
        case .launchFailed(let reason):
            return "Failed to launch CLI process: \(reason)"
        case .alreadyStarted:
            return "Session has already been started."
        case .notRunning:
            return "Session is not running."
        case .processExited(let termination):
            return "CLI process exited with code \(termination.exitCode)."
        case .controlRequestFailed(let subtype, let message, _):
            return "\(subtype) failed: \(message)"
        case .invalidResponse(let subtype):
            return "Unexpected response to \(subtype)."
        case .promptFailed(let exitCode, let stderr):
            return "Prompt failed (exit \(exitCode)): \(stderr)"
        case .authFailed(let exitCode, let stderr):
            return "claude auth failed (exit \(exitCode)): \(stderr)"
        case .versionFailed(let exitCode, let message):
            return message.isEmpty
                ? "claude --version failed (exit \(exitCode))."
                : "claude --version failed (exit \(exitCode)): \(message)"
        case .noVersion(let output):
            return "No version in the CLI's output: \(output)"
        }
    }
}
