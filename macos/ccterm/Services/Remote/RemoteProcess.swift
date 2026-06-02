import Foundation

/// Blocking `Process` runner for the remote-launch path — credential refresh,
/// managed-binary provisioning, ssh probes. Synchronous + blocking by design:
/// callers run it **off the main actor** (`RemoteLaunchCoordinator` resolves on a
/// detached task). App-layer port of `RemoteSmoke`'s `run` / `sshUploadFile`; the
/// smoke keeps its own copy (design `remote-execution.md` §3 — remote logic is
/// app-owned, AgentSDK stays transport-agnostic, no shared target).
nonisolated enum RemoteProcess {

    struct Result {
        var code: Int32
        var out: String
        var err: String
    }

    /// Run `launchPath args`, capturing stdout/stderr, killing the process if it
    /// outlives `timeout`. stdout/stderr are drained on background queues so a
    /// large output never deadlocks against a full pipe buffer.
    @discardableResult
    static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 40) -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let lock = NSLock()
        for (pipe, isOut) in [(outPipe, true), (errPipe, false)] {
            group.enter()
            DispatchQueue.global().async {
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                if isOut { outData = d } else { errData = d }
                lock.unlock()
                group.leave()
            }
        }
        do {
            try proc.run()
        } catch {
            return Result(code: -1, out: "", err: "spawn failed: \(error)")
        }
        let watchdog = DispatchQueue(label: "remote-process.watchdog")
        watchdog.asyncAfter(deadline: .now() + timeout) {
            if proc.isRunning { proc.terminate() }
        }
        proc.waitUntilExit()
        group.wait()
        return Result(
            code: proc.terminationStatus,
            out: String(data: outData, encoding: .utf8) ?? "",
            err: String(data: errData, encoding: .utf8) ?? "")
    }

    /// Stream a local file into a remote command's stdin over ssh (binary upload).
    /// `run` cannot redirect a file into stdin, so this is a small variant.
    static func uploadFile(
        localPath: String, sshArgs: [String], timeout: TimeInterval
    ) -> Int32 {
        guard let input = FileHandle(forReadingAtPath: localPath) else { return -1 }
        defer { try? input.close() }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = sshArgs
        proc.standardInput = input
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return -1 }
        let watchdog = DispatchQueue(label: "remote-process.upload.watchdog")
        watchdog.asyncAfter(deadline: .now() + timeout) { if proc.isRunning { proc.terminate() } }
        proc.waitUntilExit()
        return proc.terminationStatus
    }
}
