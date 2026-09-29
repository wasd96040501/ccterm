import Foundation

/// One-shot, non-interactive runs (`claude -p`). Nothing is persisted and no
/// session stays open; for a conversation use ``Session``.
///
/// ```swift
/// let result = try await Prompt.run("Name this repo", configuration: .init(workingDirectory: url))
/// print(result.result ?? "")
/// ```
public enum Prompt {
    /// Runs `message` to completion and returns the CLI's result. Cancelling
    /// the task, or exceeding ``PromptConfiguration/timeout``, terminates the
    /// CLI; the latter throws ``AgentSDKError/promptFailed(exitCode:stderr:)``.
    public static func run(_ message: String, configuration: PromptConfiguration) async throws -> ResultMessage {
        let process = try await Task.detached { try configuration.launch(message: message).makeProcess() }.value
        let output = try await CLIOutput.run(process, timeout: configuration.timeout)
        guard output.status == 0 else {
            let stderr = output.timedOut ? "Timed out after \(configuration.timeout ?? 0)s" : output.stderr
            throw AgentSDKError.promptFailed(exitCode: output.status, stderr: stderr)
        }
        guard let result = try? JSONDecoder().decode(ResultMessage.self, from: output.stdout) else {
            let text = String(decoding: output.stdout.prefix(500), as: UTF8.self)
            throw AgentSDKError.promptFailed(exitCode: 0, stderr: "Unexpected output: \(text)")
        }
        return result
    }
}
