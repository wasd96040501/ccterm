import AgentSDK
import XCTest

@testable import ccterm

/// Dump-only smoke tests. Spawns a real `claude` CLI via
/// `AgentSDK.Session`, sends one prompt to haiku, captures every line of
/// stdout JSONL the CLI emits, and attaches it to the xcresult / prints
/// it to stderr. We do NOT assert on protocol contents here — the file
/// the test writes IS the artifact we read.
///
/// Skipped on the default test run (filename `*SmokeTests.swift`, see
/// `scripts/test-unit.sh`). Run manually:
///
/// ```bash
/// TEST_RUNNER_RUN_SMOKE=1 make test-unit FILTER=AgentSDKMessageDumpSmokeTests
/// xcrun xcresulttool export attachments --path /tmp/ccterm-utest-*/result.xcresult \
///       --output-path /tmp/smoke-dump
/// ```
@MainActor
final class AgentSDKMessageDumpSmokeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["RUN_SMOKE"] == "1" else {
            throw XCTSkip("Set RUN_SMOKE=1 to run real-claude smoke tests")
        }
        guard Self.locateClaude() != nil else {
            throw XCTSkip("No `claude` binary in ~/.local/bin, /usr/local/bin, or PATH")
        }
    }

    // MARK: - Cases

    /// Baseline: one synchronous turn, one prompt → one `.result`.
    func testDumpSingleTurnHaiku() async throws {
        try await runDump(
            label: "single-turn",
            prompt: ProcessInfo.processInfo.environment["SMOKE_PROMPT"]
                ?? "Reply with exactly the two letters: ok",
            extraTimeoutSeconds: 0
        )
    }

    /// Ask Claude to kick off a Bash job in background mode and reply
    /// immediately. The interesting question is what the CLI emits
    /// *after* the first `.result` once the background job exits — if
    /// anything lands (assistant / progress / etc.) we need it in the
    /// dump so the new `isRunning` logic knows whether to self-heal.
    func testDumpBackgroundJobHaiku() async throws {
        try await runDump(
            label: "background-job",
            prompt: """
                Use the Bash tool with `run_in_background: true` to run \
                `sleep 5 && echo finished`. After kicking it off, reply \
                with exactly the two letters: ok.
                """,
            // After the first .result lands, keep the session open for
            // this long so any post-turn stream from the background
            // bash gets captured.
            extraTimeoutSeconds: 30
        )
    }

    // MARK: - Shared driver

    private func runDump(
        label: String,
        prompt: String,
        extraTimeoutSeconds: TimeInterval
    ) async throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let workDir = URL(
            fileURLWithPath: "/tmp/ccterm-smoke-\(label)-\(stamp)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let exportDir = workDir.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let model = ProcessInfo.processInfo.environment["SMOKE_MODEL"] ?? "claude-haiku-4-5"
        let sessionId = UUID().uuidString.lowercased()
        let claudeBin = Self.locateClaude()

        let config = SessionConfiguration(
            workingDirectory: workDir,
            model: model,
            sessionId: sessionId,
            binaryPath: claudeBin,
            inheritsParentEnvironment: true,
            allowDangerouslySkipPermissions: true,
            messageExportDirectory: exportDir
        )

        let session = AgentSDK.Session(configuration: config)
        session.lastKnownSessionId = sessionId

        let counter = MessageCounter()
        session.onMessage = { msg in
            Task { @MainActor in counter.note(msg) }
        }
        session.onStderr = { (text: String) in
            FileHandle.standardError.write(Data("[\(label) stderr] \(text)\n".utf8))
        }

        let exited = expectation(description: "[\(label)] process exited")
        session.onProcessExit = { (code: Int32) in
            FileHandle.standardError.write(Data("[\(label) exit] code=\(code)\n".utf8))
            exited.fulfill()
        }

        try await session.start()

        let initDone = expectation(description: "[\(label)] initialize replied")
        session.initialize(promptSuggestions: false) { resp in
            FileHandle.standardError.write(
                Data(
                    "[\(label) init] models=\(resp?.models?.count ?? 0)\n".utf8))
            initDone.fulfill()
        }
        await fulfillment(of: [initDone], timeout: 30)

        let gotResult = expectation(description: "[\(label)] got first .result")
        counter.onFirstResult = { gotResult.fulfill() }
        session.sendMessage(prompt, extra: ["uuid": UUID().uuidString.lowercased()])

        await fulfillment(of: [gotResult], timeout: 120)
        FileHandle.standardError.write(
            Data(
                "[\(label)] first .result received; counts: \(counter.summary())\n".utf8))

        // Hold the session open for `extraTimeoutSeconds` so anything
        // the CLI streams *after* the first .result also lands in the
        // dump. We just sleep on the main actor — no expectation, we
        // want every line that arrives in the window.
        if extraTimeoutSeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(extraTimeoutSeconds * 1_000_000_000))
            FileHandle.standardError.write(
                Data(
                    "[\(label)] post-result window done; counts: \(counter.summary())\n".utf8))
        }

        session.close()
        await fulfillment(of: [exited], timeout: 10)

        let exported = try FileManager.default.contentsOfDirectory(
            at: exportDir, includingPropertiesForKeys: nil)
        FileHandle.standardError.write(
            Data(
                "[\(label) dump] export dir = \(exportDir.path)\n".utf8))
        FileHandle.standardError.write(
            Data(
                "[\(label) dump] final counts: \(counter.summary())\n".utf8))
        for url in exported {
            FileHandle.standardError.write(
                Data(
                    "[\(label) dump] file = \(url.path)\n".utf8))
            if let data = try? Data(contentsOf: url),
                let text = String(data: data, encoding: .utf8)
            {
                let att = XCTAttachment(string: text)
                att.name = "\(label)-\(url.lastPathComponent)"
                att.lifetime = .keepAlways
                add(att)
                FileHandle.standardError.write(
                    Data(
                        "===== BEGIN \(label) \(url.lastPathComponent) =====\n".utf8))
                FileHandle.standardError.write(Data(text.utf8))
                FileHandle.standardError.write(
                    Data(
                        "\n===== END \(label) \(url.lastPathComponent) =====\n".utf8))
            }
        }
        XCTAssertFalse(exported.isEmpty, "expected at least one exported jsonl file")
    }

    // MARK: - Helpers

    /// Mirror of `AgentSDK.BinaryLocator.locate()` (internal to the SDK).
    static func locateClaude() -> String? {
        if let envPath = ProcessInfo.processInfo.environment["CLAUDE_BINARY_PATH"],
            FileManager.default.isExecutableFile(atPath: envPath)
        {
            return envPath
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in ["\(home)/.local/bin/claude", "/usr/local/bin/claude"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["claude"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty
        else { return nil }
        return path
    }

    @MainActor
    final class MessageCounter {
        private(set) var counts: [String: Int] = [:]
        var onFirstResult: (() -> Void)?
        private var firedFirstResult = false

        func note(_ message: Message2) {
            let key: String
            switch message {
            case .assistant: key = "assistant"
            case .user: key = "user"
            case .result:
                key = "result"
                if !firedFirstResult {
                    firedFirstResult = true
                    onFirstResult?()
                }
            case .system(.`init`): key = "system.init"
            case .system(.status): key = "system.status"
            case .system(.taskStarted): key = "system.task_started"
            case .system(.taskProgress): key = "system.task_progress"
            case .system(.turnDuration): key = "system.turn_duration"
            case .system: key = "system.other"
            case .progress: key = "progress"
            case .unknown(let name, _): key = "unknown(\(name))"
            default: key = "other"
            }
            counts[key, default: 0] += 1
        }

        func summary() -> String {
            counts
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
        }
    }
}
