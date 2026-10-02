import Foundation
import os

/// The CLI subprocess and its three pipes.
///
/// Stdout is split into lines and handed to `onLine` in order on one serial
/// reader; stderr is drained continuously so the child never blocks on a
/// full pipe, keeping only a bounded tail. `onExit` fires exactly once, after
/// the process has terminated **and** both pipes reached EOF, so no output
/// line can arrive after it. Writes go through a serial queue and never raise
/// `SIGPIPE`: writing to a dead child is silently dropped.
final class CLIProcess: @unchecked Sendable {
    private let process: Process
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let writeQueue = DispatchQueue(label: "AgentSDK.CLIProcess.stdin")
    private let stderrTail = OSAllocatedUnfairLock(initialState: Data())
    private let stdinOpen = OSAllocatedUnfairLock(initialState: true)
    /// Read once: `fileDescriptor` raises on a closed handle, and a write can
    /// be asked for after `closeStdin()` closed it. The write queue's
    /// `stdinOpen` check keeps the number from being used once it is closed.
    private let stdinFD: Int32

    private static let stderrTailLimit = 16 * 1024

    init(launch: CLILaunch) {
        process = launch.makeProcess()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdinFD = stdin.fileHandleForWriting.fileDescriptor
    }

    var isRunning: Bool { process.isRunning }

    /// Launches the process. `onLine` receives each non-empty stdout line.
    func run(onLine: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable (Termination) -> Void) throws {
        let finished = DispatchGroup()
        finished.enter()
        finished.enter()
        finished.enter()
        process.terminationHandler = { _ in finished.leave() }
        do {
            try process.run()
        } catch {
            throw AgentSDKError.launchFailed(error.localizedDescription)
        }
        _ = fcntl(stdinFD, F_SETNOSIGPIPE, 1)

        let stdoutFD = stdout.fileHandleForReading.fileDescriptor
        Thread.detachNewThread {
            Self.readLines(stdoutFD, onLine: onLine)
            finished.leave()
        }
        let stderrFD = stderr.fileHandleForReading.fileDescriptor
        Thread.detachNewThread { [stderrTail] in
            Self.readChunks(stderrFD) { chunk in
                stderrTail.withLock { tail in
                    tail.append(chunk)
                    if tail.count > Self.stderrTailLimit { tail = tail.suffix(Self.stderrTailLimit) }
                }
            }
            finished.leave()
        }
        finished.notify(queue: .global()) { [process, stderrTail] in
            let text = stderrTail.withLock { String(decoding: $0, as: UTF8.self) }
            onExit(Termination(exitCode: process.terminationStatus, stderr: text))
        }
    }

    /// Writes one line (a newline is appended). Dropped once stdin is closed.
    func writeLine(_ data: Data) {
        writeQueue.async { [stdinOpen, stdinFD] in
            guard stdinOpen.withLock({ $0 }) else { return }
            var line = data
            line.append(UInt8(ascii: "\n"))
            if !Self.writeAll(stdinFD, line) { stdinOpen.withLock { $0 = false } }
        }
    }

    /// Sends EOF; the CLI finishes its current turn and exits.
    func closeStdin() {
        writeQueue.async { [stdinOpen, stdin] in
            let wasOpen = stdinOpen.withLock { open in
                defer { open = false }
                return open
            }
            if wasOpen { try? stdin.fileHandleForWriting.close() }
        }
    }

    /// Sends `SIGTERM`.
    func terminate() {
        if process.isRunning { process.terminate() }
    }

    // MARK: - POSIX I/O

    private static func readChunks(_ fd: Int32, _ body: (Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                body(Data(buffer[0..<n]))
            } else if n < 0, errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    private static func readLines(_ fd: Int32, onLine: (Data) -> Void) {
        var pending = Data()
        readChunks(fd) { chunk in
            pending.append(chunk)
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: UInt8(ascii: "\n")) {
                if newline > start { onLine(Data(pending[start..<newline])) }
                start = pending.index(after: newline)
            }
            pending.removeSubrange(pending.startIndex..<start)
        }
        if !pending.isEmpty { onLine(pending) }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}
