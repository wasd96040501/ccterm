import Foundation

/// How the CLI is started for a one-off run (``Auth``, ``CLIVersion``): the
/// same launch knobs as a ``Prompt``, because the login the CLI reads is the
/// one the launched binary sees.
///
/// Precedence of an environment variable, lowest to highest: the login
/// shell's rc exports, then ``env``, then the assignments in the
/// ``customCommand`` itself (`X=1 claude`, or inside an alias it names).
public struct CLIConfiguration: Hashable, Sendable {
    /// Path to the `claude` binary; `nil` locates it.
    public var binaryPath: String?
    /// A command that replaces the binary, run through the login shell.
    public var customCommand: String?
    /// Extra environment variables.
    public var env: [String: String]
    /// Use this process's environment instead of probing the login shell.
    public var inheritsParentEnvironment: Bool
    /// Terminates a run after this many seconds; `nil` waits forever. ``Auth``
    /// applies it to `status` and `logout` only — login waits on a person in a
    /// browser.
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

    /// How to start `claude <arguments>`, from the home directory. Blocking
    /// (the login-shell environment probe).
    func launch(_ arguments: [String]) throws -> CLILaunch {
        try CLILaunch(
            arguments: arguments, workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            binaryPath: binaryPath, customCommand: customCommand, env: env,
            inheritsParentEnvironment: inheritsParentEnvironment)
    }
}
