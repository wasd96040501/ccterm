import AgentSDK
import Foundation

// Smoke test for `Session.getContextUsage`.
//
// Boots a real CLI session in plan mode (so it cannot run any tool that
// would burn credits), runs `initialize`, fires `getContextUsage`, and
// verifies the response carries the expected typed fields. Then runs a
// second probe with a 100 ms timeout to confirm the timeout path
// surfaces `.unsupported` without crashing.
//
// Run from `macos/AgentSDK`:
//
//   swift run ContextUsageSmoke
//
// Env:
//   CLAUDE_BINARY_PATH      override the binary lookup
//   SMOKE_TIMEOUT_SECONDS   how long to wait for the real response (default 10)

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(ts)] \(msg)\n".utf8))
}

func locateClaude() -> String? {
    if let env = ProcessInfo.processInfo.environment["CLAUDE_BINARY_PATH"],
        FileManager.default.isExecutableFile(atPath: env)
    {
        return env
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    for p in ["\(home)/.local/bin/claude", "/usr/local/bin/claude"] {
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
}

let env = ProcessInfo.processInfo.environment
let realTimeout = TimeInterval(Int(env["SMOKE_TIMEOUT_SECONDS"] ?? "10") ?? 10)

guard let claudeBin = locateClaude() else {
    log("ERROR: no claude binary found (set CLAUDE_BINARY_PATH)")
    exit(1)
}

let workDir = URL(
    fileURLWithPath: "/tmp/ccterm-context-usage-smoke-\(Int(Date().timeIntervalSince1970))",
    isDirectory: true)
try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

let config = SessionConfiguration(
    workingDirectory: workDir,
    permissionMode: .plan,
    binaryPath: claudeBin,
    systemPrompt: .custom("You are a smoke harness. Do nothing on your own."),
    maxTurns: 1
)
let session = Session(configuration: config)

let initDone = DispatchSemaphore(value: 0)
session.onProcessExit = { (code: Int32) in log("[exit] code=\(code)") }
session.onStderr = { (text: String) in
    for line in text.split(separator: "\n") {
        log("[cli:stderr] \(line)")
    }
}

do {
    try await session.start()
} catch {
    log("ERROR: start failed: \(error)")
    exit(1)
}

session.initialize(promptSuggestions: false) { resp in
    log("[init] commands=\(resp?.commands?.count ?? -1)")
    initDone.signal()
}
if initDone.wait(timeout: .now() + 10) == .timedOut {
    log("ERROR: initialize timed out — CLI is too old or stuck")
    session.close()
    exit(2)
}

// --- Real probe -----------------------------------------------------------
let realDone = DispatchSemaphore(value: 0)
var realOutcome: ContextUsageOutcome = .unsupported
session.getContextUsage(timeout: realTimeout) { outcome in
    realOutcome = outcome
    realDone.signal()
}
if realDone.wait(timeout: .now() + realTimeout + 2) == .timedOut {
    log("ERROR: getContextUsage callback never fired — should have at least timed out")
    session.close()
    exit(3)
}
switch realOutcome {
case .usage(let usage):
    log(
        "[real] OK rawMaxTokens=\(usage.rawMaxTokens) totalTokens=\(usage.totalTokens) "
            + "percentage=\(usage.percentage) categories=\(usage.categories.count) "
            + "memoryFiles=\(usage.memoryFiles.count) mcpTools=\(usage.mcpTools.count)")
    guard usage.rawMaxTokens > 0 else {
        log("ERROR: rawMaxTokens=0 in real response")
        session.close()
        exit(4)
    }
    for cat in usage.categories.prefix(5) {
        log("[real]   • \(cat.name): \(cat.tokens) (deferred=\(cat.isDeferred))")
    }
case .unsupported:
    log("[real] UNSUPPORTED — running against an old CLI? rebuild and rerun")
case .sdkError(let msg):
    log("ERROR: real probe sdkError: \(msg)")
    session.close()
    exit(5)
}

// --- Timeout probe --------------------------------------------------------
// 0.001s timeout: there is no way the CLI replies that fast, so we expect
// `.unsupported` and a callback that fires exactly once.
let timeoutDone = DispatchSemaphore(value: 0)
var timeoutOutcome: ContextUsageOutcome = .usage(try! ContextUsage(json: [:]))
var timeoutFireCount = 0
session.getContextUsage(timeout: 0.001) { outcome in
    timeoutFireCount += 1
    timeoutOutcome = outcome
    timeoutDone.signal()
}
if timeoutDone.wait(timeout: .now() + 3) == .timedOut {
    log("ERROR: timeout probe callback never fired")
    session.close()
    exit(6)
}
guard case .unsupported = timeoutOutcome else {
    log("ERROR: expected .unsupported for 1ms timeout, got \(timeoutOutcome)")
    session.close()
    exit(7)
}
// Wait a beat to confirm a late CLI response doesn't fire the completion
// a second time.
Thread.sleep(forTimeInterval: 1.5)
guard timeoutFireCount == 1 else {
    log("ERROR: completion fired \(timeoutFireCount) times — race in timeout path")
    session.close()
    exit(8)
}
log("[timeout] OK (.unsupported, fired exactly once)")

session.close()
log("SMOKE PASS")
exit(0)
