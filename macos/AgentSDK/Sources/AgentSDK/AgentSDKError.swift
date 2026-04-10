import Foundation

public enum AgentSDKError: Error, LocalizedError {
    case binaryNotFound
    case launchFailed(underlying: Error)
    case sessionNotStarted
    case alreadyRunning
    case promptFailed(exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "CLI binary not found. Install it or set binaryPath in configuration."
        case .launchFailed(let error):
            return "Failed to launch CLI process: \(error.localizedDescription)"
        case .sessionNotStarted:
            return "Session has not been started. Call start() first."
        case .alreadyRunning:
            return "Session is already running."
        case .promptFailed(let exitCode, let stderr):
            return "Prompt failed (exit \(exitCode)): \(stderr)"
        }
    }
}
