import Foundation

/// A CLI that runs, and the version it reports.
public struct CLIVersion: Hashable, Sendable {
    /// What was run: the resolved binary path, or a custom command's text.
    public let executable: String
    /// The `major.minor.patch` the CLI printed for `--version`.
    public let version: String

    /// Runs `<launch> --version` for `configuration` off the main thread, bounded
    /// by its `timeout`.
    ///
    /// - Throws: ``AgentSDKError/binaryNotFound``, ``AgentSDKError/launchFailed(_:)``,
    ///   ``AgentSDKError/versionFailed(exitCode:message:)`` (non-zero exit or timeout)
    ///   and ``AgentSDKError/noVersion(output:)`` when the output has no version.
    public static func probe(_ configuration: CLIConfiguration) async throws -> CLIVersion {
        let launch = try await Task.detached { try configuration.launch(["--version"]) }.value
        let output = try await CLIOutput.run(launch.makeProcess(), timeout: configuration.timeout)
        if output.timedOut {
            throw AgentSDKError.versionFailed(
                exitCode: output.status, message: "Timed out after \(configuration.timeout ?? 0)s")
        }
        let text = String(decoding: output.stdout, as: UTF8.self)
        guard output.status == 0 else {
            let last = output.stderr.split(whereSeparator: \.isNewline).last.map(String.init)
            throw AgentSDKError.versionFailed(
                exitCode: output.status, message: last?.trimmingCharacters(in: .whitespaces) ?? "")
        }
        guard let version = version(in: text) else { throw AgentSDKError.noVersion(output: String(text.prefix(500))) }
        let custom = configuration.customCommand.flatMap { $0.isEmpty ? nil : $0 }
        return CLIVersion(executable: custom ?? launch.executable, version: version)
    }

    /// The first `x.y.z` in `output` (`2.1.284 (Claude Code)`).
    static func version(in output: String) -> String? {
        output.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression).map { String(output[$0]) }
    }
}
