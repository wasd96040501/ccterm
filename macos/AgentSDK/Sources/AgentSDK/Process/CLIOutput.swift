import Foundation

/// A CLI run to its exit: the status and everything it wrote.
struct CLIOutput {
    var status: Int32
    var stdout: Data
    var stderr: String
    var timedOut: Bool

    /// Runs `process` to exit, draining both pipes concurrently so a full
    /// stderr pipe cannot stall it. `onOutput` sees stdout as it arrives, in
    /// chunks as the pipe delivers them. Cancelling the calling task
    /// terminates the process.
    static func run(
        _ process: Process, timeout: TimeInterval?, onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> CLIOutput {
        let output = try await withTaskCancellationHandler {
            try await Task.detached { try collect(process, timeout: timeout, onOutput: onOutput) }.value
        } onCancel: {
            process.terminate()
        }
        try Task.checkCancellation()
        return output
    }

    private static func collect(
        _ process: Process, timeout: TimeInterval?, onOutput: (@Sendable (String) -> Void)?
    ) throws -> CLIOutput {
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
        var outputData = Data()
        if let onOutput {
            while case let chunk = stdout.fileHandleForReading.availableData, !chunk.isEmpty {
                outputData.append(chunk)
                onOutput(String(decoding: chunk, as: UTF8.self))
            }
        } else {
            outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        }
        drained.wait()
        process.waitUntilExit()
        watchdog.cancel()

        return CLIOutput(
            status: process.terminationStatus, stdout: outputData,
            stderr: String(decoding: errorData, as: UTF8.self), timedOut: timedOut)
    }
}
