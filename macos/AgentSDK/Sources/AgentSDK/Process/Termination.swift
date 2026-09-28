import Foundation

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
