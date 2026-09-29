import Foundation

/// How to start the CLI: the executable, its full command line, where it
/// runs and its environment. ``Session`` and ``Prompt`` each build only the
/// CLI arguments they need; resolving the rest is the same for both and
/// happens here.
struct CLILaunch: Sendable {
    var executable: String
    var arguments: [String]
    var workingDirectory: URL
    var environment: [String: String]

    /// Resolves the executable and environment for a CLI run with
    /// `arguments`. Blocking (the login-shell environment probe can take
    /// seconds); call off the main thread.
    ///
    /// - A non-empty `customCommand` replaces the binary and runs through the
    ///   user's login shell, so aliases, functions and `~`/`$VAR` expansion
    ///   behave as at a prompt; `arguments` ride in `"$@"`. Otherwise the
    ///   binary is `binaryPath`, else the located `claude`.
    /// - The environment is the login shell's — or this process's, when
    ///   `inheritsParentEnvironment` or when the probe fails — without
    ///   `CLAUDECODE`, with `env` on top. A custom command's shell sources the
    ///   rc files after the process environment is set, so `env` is also
    ///   exported inside its script: rc exports < `env` < the command's own
    ///   assignments.
    init(
        arguments: [String], workingDirectory: URL, binaryPath: String?, customCommand: String?,
        env: [String: String], inheritsParentEnvironment: Bool
    ) throws {
        if let customCommand, !customCommand.isEmpty {
            (executable, self.arguments) = CustomCommand.shellInvocation(
                customCommand, sdkArgs: arguments, exports: env)
        } else {
            guard let resolved = binaryPath ?? BinaryLocator.locate() else { throw AgentSDKError.binaryNotFound }
            (executable, self.arguments) = (resolved, arguments)
        }

        var environment =
            inheritsParentEnvironment
            ? ProcessInfo.processInfo.environment
            : (ShellEnvironment.loginEnvironment() ?? ProcessInfo.processInfo.environment)
        environment.removeValue(forKey: "CLAUDECODE")
        environment.merge(env) { _, override in override }

        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    /// The configured, unlaunched process.
    func makeProcess() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        return process
    }
}
