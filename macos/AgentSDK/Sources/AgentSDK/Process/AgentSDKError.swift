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
    /// The CLI answered a control request with an error.
    case controlRequestFailed(subtype: String, message: String)
    /// The CLI's answer to a control request did not have the expected shape.
    case invalidResponse(subtype: String)
    /// A one-shot ``Prompt`` run failed.
    case promptFailed(exitCode: Int32, stderr: String)

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
        case .controlRequestFailed(let subtype, let message):
            return "\(subtype) failed: \(message)"
        case .invalidResponse(let subtype):
            return "Unexpected response to \(subtype)."
        case .promptFailed(let exitCode, let stderr):
            return "Prompt failed (exit \(exitCode)): \(stderr)"
        }
    }
}
