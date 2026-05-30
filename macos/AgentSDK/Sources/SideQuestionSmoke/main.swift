import AgentSDK
import Foundation

// Smoke test for `Session.askSideQuestion` — the `side_question` control
// request behind the CLI's `/btw` slash command.
//
// Boots a real CLI session in plan mode (so it can't run a tool that burns
// credits), seeds one turn that plants a secret into the conversation, then
// fires `askSideQuestion` and verifies:
//   1. the answer recalls the secret purely from *shared context* we never
//      re-sent — proving the host answered from its own message history;
//   2. `synthetic == false` (a real model answer, not a tool-attempt / error);
//   3. the side question did NOT advance the main turn loop (no new `.result`).
//
// Run from `macos/AgentSDK`:
//
//   swift run SideQuestionSmoke
//
// Env:
//   CLAUDE_BINARY_PATH      override the binary lookup
//   SMOKE_TIMEOUT_SECONDS   how long to wait for the side answer (default 60)

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

let secret = "PURPLE-RHINO-7"
let env = ProcessInfo.processInfo.environment
let realTimeout = TimeInterval(Int(env["SMOKE_TIMEOUT_SECONDS"] ?? "60") ?? 60)

guard let claudeBin = locateClaude() else {
    log("ERROR: no claude binary found (set CLAUDE_BINARY_PATH)")
    exit(1)
}

let workDir = URL(
    fileURLWithPath: "/tmp/ccterm-side-question-smoke-\(Int(Date().timeIntervalSince1970))",
    isDirectory: true)
try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

let config = SessionConfiguration(
    workingDirectory: workDir,
    permissionMode: .plan,
    binaryPath: claudeBin,
    systemPrompt: .custom("You are a smoke harness. Answer briefly. Do nothing on your own."),
    maxTurns: 1
)
let session = Session(configuration: config)

// Count `.result` messages so we can prove the side question is "by the way":
// it must not produce a new turn result on the main stream.
var resultCount = 0
let seedResult = DispatchSemaphore(value: 0)
session.onMessage = { (message: Message2) in
    switch message {
    case .assistant(let a):
        let texts: [String] = (a.message?.content ?? []).compactMap {
            if case .text(let t) = $0, let txt = t.text, !txt.isEmpty { return String(txt.prefix(60)) }
            return nil
        }
        if !texts.isEmpty { log("[asst] \(texts)") }
    case .result:
        resultCount += 1
        log("[result #\(resultCount)]")
        if resultCount == 1 { seedResult.signal() }
    case .system(.`init`):
        log("[system.init]")
    default:
        break
    }
}
session.onProcessExit = { (code: Int32) in log("[exit] code=\(code)") }
session.onStderr = { (text: String) in
    for line in text.split(separator: "\n") { log("[cli:stderr] \(line)") }
}

do {
    try await session.start()
} catch {
    log("ERROR: start failed: \(error)")
    exit(1)
}

let initDone = DispatchSemaphore(value: 0)
session.initialize(promptSuggestions: false) { resp in
    log("[init] commands=\(resp?.commands?.count ?? -1)")
    initDone.signal()
}
if initDone.wait(timeout: .now() + 10) == .timedOut {
    log("ERROR: initialize timed out — CLI is too old or stuck")
    session.close()
    exit(2)
}

// --- Seed turn: plant the secret into the conversation --------------------
log("[seed] sending context-priming turn")
session.sendMessage("Remember this for our conversation: the launch code is \(secret). Reply with only: ok")
if seedResult.wait(timeout: .now() + realTimeout) == .timedOut {
    log("ERROR: seed turn never produced a result")
    session.close()
    exit(3)
}
let resultsBeforeSide = resultCount

// --- Real probe: ask the side question ------------------------------------
log("[side] firing askSideQuestion (side_question control request)")
let sideDone = DispatchSemaphore(value: 0)
var sideOutcome: SideQuestionOutcome = .unsupported
session.askSideQuestion(
    "What launch code did I just tell you? Answer with ONLY the code, nothing else."
) { outcome in
    sideOutcome = outcome
    sideDone.signal()
}
// `realTimeout` bounds the smoke's own wait, not the SDK call (which has no
// client-side timeout) — so a hung run fails fast instead of blocking forever.
if sideDone.wait(timeout: .now() + realTimeout + 2) == .timedOut {
    log("ERROR: askSideQuestion callback never fired within \(realTimeout)s")
    session.close()
    exit(4)
}

switch sideOutcome {
case .answer(let a):
    log("[side] response=\(a.response.prefix(120).debugDescription) synthetic=\(a.synthetic)")
    guard a.response.contains(secret) else {
        log("ERROR: answer did not recall the secret from shared context: \(a.response.debugDescription)")
        session.close()
        exit(5)
    }
    guard !a.synthetic else {
        log("ERROR: answer is synthetic (model tried a tool / API error), expected a real answer")
        session.close()
        exit(6)
    }
case .empty:
    log("ERROR: side question returned empty (no text)")
    session.close()
    exit(7)
case .unsupported:
    log("ERROR: UNSUPPORTED — old CLI without side_question? rebuild and rerun")
    session.close()
    exit(8)
case .sdkError(let msg):
    log("ERROR: side question sdkError: \(msg)")
    session.close()
    exit(9)
}

// "By the way" check: the side question must not have advanced the main loop.
Thread.sleep(forTimeInterval: 0.5)
guard resultCount == resultsBeforeSide else {
    let extra = resultCount - resultsBeforeSide
    log("ERROR: side question produced \(extra) new turn result(s) — it interrupted the main loop")
    session.close()
    exit(10)
}
log("[side] OK — recalled secret from shared context, real answer, 0 new main-loop turns")

session.close()
log("SMOKE PASS")
exit(0)
