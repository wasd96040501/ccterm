import AgentSDK
import Foundation

// Dump-only smoke. Spawns a real `claude` CLI via AgentSDK.Session,
// sends one prompt, captures every line of JSONL the CLI emits, and
// prints message-type counts. Two scenarios are selectable by env:
//
//   SMOKE_SCENARIO=single   (default) — one turn, one prompt → one .result
//   SMOKE_SCENARIO=bgjob              — ask claude to kick off a background
//                                       bash and reply immediately, then
//                                       keep the session open for 30s to
//                                       capture post-`.result` traffic
//
// Env: CLAUDE_BINARY_PATH (override), SMOKE_MODEL (default
// claude-haiku-4-5).
//
// Run from `macos/AgentSDK`:
//
//   swift run DumpSmoke
//   SMOKE_SCENARIO=bgjob swift run DumpSmoke
//
// This used to be an XCTest target inside cctermTests, but those tests
// bundle-load the host app and hang on its GitProbe startup probe on
// some machines. Standalone executable keeps the smoke working
// regardless of host-app state.

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(ts)] \(msg)\n".utf8))
}

func locateClaude() -> String? {
    if let envPath = ProcessInfo.processInfo.environment["CLAUDE_BINARY_PATH"],
        FileManager.default.isExecutableFile(atPath: envPath)
    {
        return envPath
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    for p in ["\(home)/.local/bin/claude", "/usr/local/bin/claude"] {
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
}

enum Scenario: String { case single, bgjob }

let env = ProcessInfo.processInfo.environment
let scenario = Scenario(rawValue: env["SMOKE_SCENARIO"] ?? "single") ?? .single
let model = env["SMOKE_MODEL"] ?? "claude-haiku-4-5"
let prompt: String
let extraDrainSeconds: TimeInterval
switch scenario {
case .single:
    prompt = env["SMOKE_PROMPT"] ?? "Reply with exactly the two letters: ok"
    extraDrainSeconds = 0
case .bgjob:
    prompt =
        env["SMOKE_PROMPT"]
            ?? """
            Use the Bash tool with `run_in_background: true` to run \
            `sleep 5 && echo finished`. After kicking it off, reply \
            with exactly the two letters: ok.
            """
    extraDrainSeconds = 30
}

guard let claudeBin = locateClaude() else {
    log("ERROR: no claude binary found")
    exit(1)
}

let stamp = Int(Date().timeIntervalSince1970)
let workDir = URL(fileURLWithPath: "/tmp/ccterm-dump-smoke-\(scenario.rawValue)-\(stamp)", isDirectory: true)
let exportDir = workDir.appendingPathComponent("export", isDirectory: true)
try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

let sessionId = UUID().uuidString.lowercased()

log("scenario=\(scenario.rawValue) model=\(model) sessionId=\(sessionId)")
log("workDir=\(workDir.path)")

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

var counts: [String: Int] = [:]
let firstResult = DispatchSemaphore(value: 0)
var resultFired = false
let processExited = DispatchSemaphore(value: 0)

session.onMessage = { msg in
    let key: String
    switch msg {
    case .assistant: key = "assistant"
    case .user: key = "user"
    case .result:
        key = "result"
        if !resultFired {
            resultFired = true
            firstResult.signal()
        }
    case .system(.`init`): key = "system.init"
    case .system: key = "system.other"
    case .progress: key = "progress"
    case .unknown(let n, _): key = "unknown(\(n))"
    default: key = "other"
    }
    counts[key, default: 0] += 1
}
session.onStderr = { text in
    log("[stderr] \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
}
session.onProcessExit = { code in
    log("[exit] code=\(code)")
    processExited.signal()
}

do {
    try await session.start()
    log("session.start ok")
} catch {
    log("ERROR session.start: \(error)")
    exit(1)
}

let initDone = DispatchSemaphore(value: 0)
session.initialize(promptSuggestions: false) { resp in
    log("init reply: models=\(resp?.models?.count ?? 0)")
    initDone.signal()
}
if initDone.wait(timeout: .now() + 30) == .timedOut {
    log("ERROR initialize timeout")
    session.close()
    exit(1)
}

log("sending prompt…")
session.sendMessage(prompt, extra: ["uuid": UUID().uuidString.lowercased()])

if firstResult.wait(timeout: .now() + 120) == .timedOut {
    log("ERROR first .result timeout")
    session.close()
    exit(1)
}
log("first .result received — counts: \(counts.sorted { $0.key < $1.key })")

if extraDrainSeconds > 0 {
    log("post-result drain window \(Int(extraDrainSeconds))s")
    Thread.sleep(forTimeInterval: extraDrainSeconds)
    log("post-result counts: \(counts.sorted { $0.key < $1.key })")
}

log("closing session")
session.close()
if processExited.wait(timeout: .now() + 10) == .timedOut {
    log("WARN process did not exit within 10s of close")
}

// Dump JSONL.
if let files = try? FileManager.default.contentsOfDirectory(at: exportDir, includingPropertiesForKeys: nil) {
    for url in files {
        log("--- export: \(url.lastPathComponent) ---")
        if let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
        {
            FileHandle.standardError.write(Data(text.utf8))
            FileHandle.standardError.write(Data("\n".utf8))
        }
    }
}
log("done")
