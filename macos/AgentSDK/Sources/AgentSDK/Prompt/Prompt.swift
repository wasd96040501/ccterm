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
        let process = try await Task.detached { try configuration.makeProcess(message: message) }.value
        let output = try await withTaskCancellationHandler {
            try await Task.detached { try collect(process, timeout: configuration.timeout) }.value
        } onCancel: {
            process.terminate()
        }
        try Task.checkCancellation()
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

    private struct Output {
        var status: Int32
        var stdout: Data
        var stderr: String
        var timedOut: Bool
    }

    /// Runs the process to exit, draining both pipes concurrently so a full
    /// stderr pipe cannot stall it. Blocking.
    private static func collect(_ process: Process, timeout: TimeInterval?) throws -> Output {
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw AgentSDKError.launchFailed(error.localizedDescription)
        }

        var timedOut = false
        let watchdog = DispatchWorkItem {
            timedOut = true
            process.terminate()
        }
        if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog) }

        var errorData = Data()
        let drained = DispatchGroup()
        DispatchQueue.global().async(group: drained) {
            errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        }
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()
        watchdog.cancel()

        return Output(
            status: process.terminationStatus, stdout: outputData,
            stderr: String(decoding: errorData, as: UTF8.self), timedOut: timedOut)
    }
}
