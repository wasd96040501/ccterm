import Foundation

/// How ``Auth`` starts the CLI. The same launch knobs as a ``Prompt``: the
/// login the CLI reads is the one the launched binary sees.
public struct AuthConfiguration: Sendable {
    /// Path to the `claude` binary; `nil` locates it.
    public var binaryPath: String?
    /// A command that replaces the binary, run through the login shell.
    public var customCommand: String?
    /// Extra environment variables.
    public var env: [String: String]
    /// Use this process's environment instead of probing the login shell.
    public var inheritsParentEnvironment: Bool
    /// Terminates `status` and `logout` after this many seconds. Login waits
    /// on a person in a browser and has none.
    public var timeout: TimeInterval?

    public init(
        binaryPath: String? = nil, customCommand: String? = nil, env: [String: String] = [:],
        inheritsParentEnvironment: Bool = false, timeout: TimeInterval? = 30
    ) {
        self.binaryPath = binaryPath
        self.customCommand = customCommand
        self.env = env
        self.inheritsParentEnvironment = inheritsParentEnvironment
        self.timeout = timeout
    }

    /// How to start `claude auth <arguments>`. Blocking (the login-shell
    /// environment probe).
    func launch(_ arguments: [String]) throws -> CLILaunch {
        try CLILaunch(
            arguments: ["auth"] + arguments, workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            binaryPath: binaryPath, customCommand: customCommand, env: env,
            inheritsParentEnvironment: inheritsParentEnvironment)
    }
}
