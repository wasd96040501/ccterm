import AgentSDK
import Foundation

// Queue-timing smoke. Sends one prompt via AgentSDK and timestamps every
// inbound event so we can see the ordering of:
//
//   T0     — sendMessage call (queued at our side)
//   T_init — system.init landed (CLI ready)
//   T_user — `user` echo with our uuid (the --replay-user-messages signal;
//            this is what flips ccterm's bubble from .queued → .confirmed)
//   T_pgs  — first `progress` event (stream_event delta; earliest sign
//            assistant has started producing)
//   T_asst — first full `assistant` message
//   T_res  — `result` (turn end)
//
// Run from `macos/AgentSDK`:
//
//   swift run QueueTimingSmoke
//
// Env: CLAUDE_BINARY_PATH (override), SMOKE_MODEL (default claude-haiku-4-5),
//      SMOKE_PROMPT (default makes a multi-sentence reply so streaming is
//      visible).

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

let env = ProcessInfo.processInfo.environment
let model = env["SMOKE_MODEL"] ?? "claude-haiku-4-5"
let prompt =
    env["SMOKE_PROMPT"]
    ?? "Write three short sentences about sunsets. No preamble."

guard let claudeBin = locateClaude() else {
    FileHandle.standardError.write(Data("ERROR: no claude binary found\n".utf8))
    exit(1)
}

let stamp = Int(Date().timeIntervalSince1970)
let workDir = URL(
    fileURLWithPath: "/tmp/ccterm-queue-timing-\(stamp)", isDirectory: true)
try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

let sessionId = UUID().uuidString.lowercased()

let config = SessionConfiguration(
    workingDirectory: workDir,
    model: model,
    sessionId: sessionId,
    binaryPath: claudeBin,
    inheritsParentEnvironment: true,
    allowDangerouslySkipPermissions: true,
    messageExportDirectory: nil
)

let session = AgentSDK.Session(configuration: config)
session.lastKnownSessionId = sessionId

// All times in ms relative to T0 (set right before sendMessage).
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var t0: Date?

    func mark() {
        lock.lock()
        t0 = Date()
        lock.unlock()
    }
    func ms() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let t0 else { return "  pre" }
        let dt = Date().timeIntervalSince(t0) * 1000
        return String(format: "%+5.0f", dt)
    }
}
let clock = Clock()

func log(_ tag: String, _ msg: String) {
    let line = "[\(clock.ms()) ms] [\(tag)] \(msg)\n"
    FileHandle.standardError.write(Data(line.utf8))
}

// Track first-arrivals per category. Print summary at the end.
final class Marks: @unchecked Sendable {
    var initAt: Date?
    var userEchoAt: Date?
    var firstProgressAt: Date?
    var firstAssistantAt: Date?
    var resultAt: Date?
    var assistantCount = 0
    var progressCount = 0
    var userCount = 0

    // Per-subtype first-arrival. Lets us spot "task_started" /
    // "task_updated" / etc that arrive before T_user and would make
    // better confirm signals.
    var firstByLabel: [String: Date] = [:]
    var countByLabel: [String: Int] = [:]
    func note(_ label: String) {
        countByLabel[label, default: 0] += 1
        if firstByLabel[label] == nil { firstByLabel[label] = Date() }
    }
}
let marks = Marks()

let userUuid = UUID().uuidString.lowercased()
// Track every uuid we've issued in `sendMessage extra` so the labeler
// can identify echo across multiple turns.
final class OurUuids: @unchecked Sendable {
    private let lock = NSLock()
    private var set: Set<String> = []
    func add(_ u: String) {
        lock.lock()
        set.insert(u)
        lock.unlock()
    }
    func contains(_ u: String?) -> Bool {
        guard let u else { return false }
        lock.lock()
        defer { lock.unlock() }
        return set.contains(u)
    }
}
let ourUuids = OurUuids()
ourUuids.add(userUuid)

let firstResult = DispatchSemaphore(value: 0)
var resultFired = false

session.onMessage = { msg in
    // Label every event with a fine-grained tag so the timeline shows
    // exactly which event types arrive between T0 and T_user / T_asst.
    // Anything that lands EARLIER than `user.echo(ours)` is a candidate
    // for a faster queued→confirmed signal.
    let label: String
    switch msg {
    case .assistant: label = "assistant"
    case .customTitle: label = "customTitle"
    case .fileHistorySnapshot: label = "fileHistorySnapshot"
    case .lastPrompt: label = "lastPrompt"
    case .progress: label = "progress"
    case .promptSuggestion: label = "promptSuggestion"
    case .queueOperation: label = "queueOperation"
    case .rateLimitEvent: label = "rateLimitEvent"
    case .result: label = "result"
    case .user(let u):
        label = ourUuids.contains(u.uuid) ? "user.echo(ours)" : "user.other"
    case .worktreeState: label = "worktreeState"
    case .unknown(let n, _): label = "unknown(\(n))"
    case .system(let s):
        switch s {
        case .apiError: label = "system.apiError"
        case .compactBoundary: label = "system.compactBoundary"
        case .informational: label = "system.informational"
        case .`init`: label = "system.init"
        case .localCommand: label = "system.localCommand"
        case .microcompactBoundary: label = "system.microcompactBoundary"
        case .status: label = "system.status"
        case .taskNotification: label = "system.taskNotification"
        case .taskProgress: label = "system.taskProgress"
        case .taskStarted: label = "system.taskStarted"
        case .taskUpdated: label = "system.taskUpdated"
        case .turnDuration: label = "system.turnDuration"
        case .unknown(let n, _): label = "system.unknown(\(n))"
        }
    }

    marks.note(label)
    let isFirst = marks.countByLabel[label] == 1
    let firstTag = isFirst ? "FIRST " : ""

    // Extra detail on the candidates we care about, so we can see if
    // they carry our user-message uuid (and are therefore per-message
    // signals usable for confirm).
    var detail = ""
    switch msg {
    case .system(.status(let s)):
        detail = "  raw=\(s._raw)"
    case .system(.taskStarted(let t)):
        detail = "  raw=\(t._raw)"
    case .system(.taskUpdated(let t)):
        detail = "  raw=\(t._raw)"
    case .rateLimitEvent(let r):
        detail = "  raw=\(r._raw)"
    case .user(let u):
        detail = "  uuid=\(u.uuid?.prefix(8).description ?? "(nil)")"
    default: break
    }

    log(label, "\(firstTag)#\(marks.countByLabel[label] ?? 0)\(detail)")

    // Headline summary marks (kept for the existing summary block).
    switch msg {
    case .system(.`init`) where marks.initAt == nil:
        marks.initAt = Date()
    case .user(let u):
        marks.userCount += 1
        if u.uuid == userUuid && marks.userEchoAt == nil {
            marks.userEchoAt = Date()
        }
    case .progress:
        marks.progressCount += 1
        if marks.firstProgressAt == nil { marks.firstProgressAt = Date() }
    case .assistant:
        marks.assistantCount += 1
        if marks.firstAssistantAt == nil { marks.firstAssistantAt = Date() }
    case .result:
        if marks.resultAt == nil { marks.resultAt = Date() }
        if !resultFired {
            resultFired = true
            firstResult.signal()
        }
    default: break
    }
}
session.onStderr = { text in
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    log("stderr", trimmed)
}
session.onProcessExit = { code in
    log("exit", "code=\(code)")
}

log("setup", "model=\(model) prompt=\"\(prompt)\"")
log("setup", "our uuid=\(userUuid.prefix(8))")

do {
    try await session.start()
    log("session.start", "ok")
} catch {
    log("ERROR", "session.start: \(error)")
    exit(1)
}

let initDone = DispatchSemaphore(value: 0)
session.initialize(promptSuggestions: false) { resp in
    log("initialize", "reply models=\(resp?.models?.count ?? 0)")
    initDone.signal()
}
if initDone.wait(timeout: .now() + 30) == .timedOut {
    log("ERROR", "initialize timeout")
    session.close()
    exit(1)
}

// SMOKE_BACK_TO_BACK=1 — fire two sends in rapid succession (no wait
// in between) and observe how many `system.init` events the CLI
// emits. This tells us whether system.init is 1:1 with sendMessage
// (per stdin write) or 1:1 with turn-actually-started (per CLI batch).
if env["SMOKE_BACK_TO_BACK"] == "1" {
    let secondPromptBB = env["SMOKE_PROMPT2"] ?? "Reply with exactly: ok"
    let secondUuid = UUID().uuidString.lowercased()
    ourUuids.add(secondUuid)
    clock.mark()
    log("send", "T0 — back-to-back: send #1 (uuid=\(userUuid.prefix(8)))")
    session.sendMessage(prompt, extra: ["uuid": userUuid])
    // Small but real gap so the second send arrives while the CLI is
    // still ingesting the first. 5ms is more than enough on a unix
    // socket / pipe; pick larger to be safe.
    Thread.sleep(forTimeInterval: 0.005)
    log("send", "T0+ — back-to-back: send #2 (uuid=\(secondUuid.prefix(8)))")
    session.sendMessage(secondPromptBB, extra: ["uuid": secondUuid])

    // Wait for both turns to complete. We need TWO .result events.
    var resultsToWait = 2
    // Reuse `firstResult` semaphore but re-arm via resultFired counter
    // … actually simpler: wait for the per-label `result` count.
    let deadline = Date().addingTimeInterval(180)
    while (marks.countByLabel["result"] ?? 0) < 2, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    _ = resultsToWait
    Thread.sleep(forTimeInterval: 1.0)

    log("send", "—————— back-to-back summary ——————")
    log("send", "  system.init count        : \(marks.countByLabel["system.init"] ?? 0)")
    log("send", "  user.echo(ours) count    : \(marks.countByLabel["user.echo(ours)"] ?? 0)")
    log("send", "  assistant count          : \(marks.countByLabel["assistant"] ?? 0)")
    log("send", "  result count             : \(marks.countByLabel["result"] ?? 0)")
    session.close()
    exit(0)
}

// T0: the exact moment ccterm would set `delivery = .queued` and emit
// the user bubble. Everything below is the "wall clock" gap the user
// perceives between hitting send and seeing the queued visual clear.
clock.mark()
log("send", "T0 — sendMessage about to fire (uuid=\(userUuid.prefix(8)))")
session.sendMessage(prompt, extra: ["uuid": userUuid])

if firstResult.wait(timeout: .now() + 120) == .timedOut {
    log("ERROR", "first .result timeout")
    session.close()
    exit(1)
}

// Drain a touch in case a late user echo trails the result.
Thread.sleep(forTimeInterval: 1.0)

// Second send on the same session — checks whether system.status /
// rateLimitEvent fire per-turn or only on session boot. If only the
// first turn carries them, they aren't usable as per-message confirm
// signals (only the very first send of a session benefits).
let secondPrompt = env["SMOKE_PROMPT2"] ?? "Reply with exactly: ok"
if env["SMOKE_SKIP_SECOND"] == nil {
    let secondUuid = UUID().uuidString.lowercased()
    ourUuids.add(secondUuid)
    log("send", "—————— second turn ——————")
    log("send", "T0' — second sendMessage (uuid=\(secondUuid.prefix(8)))")
    resultFired = false
    let baselineLabels = marks.countByLabel
    clock.mark()  // reset T0 to the second send for cleaner deltas
    // Track which events appear ONLY on the second turn (count went up).
    session.sendMessage(secondPrompt, extra: ["uuid": secondUuid])
    if firstResult.wait(timeout: .now() + 60) == .timedOut {
        log("ERROR", "second .result timeout")
    } else {
        Thread.sleep(forTimeInterval: 0.5)
        log("send", "—————— second-turn deltas ——————")
        for (label, count) in marks.countByLabel.sorted(by: { $0.key < $1.key }) {
            let prev = baselineLabels[label] ?? 0
            let diff = count - prev
            if diff > 0 {
                log("send", "  +\(diff)  \(label)  (turn1=\(prev), turn2=\(count))")
            }
        }
    }
}

log("summary", "—————————— summary ——————————")
func ms(from t0: Date?, to t: Date?) -> String {
    guard let t0, let t else { return "    n/a" }
    return String(format: "%+5.0f ms", t.timeIntervalSince(t0) * 1000)
}
let t0Date = clock.t0
log("summary", "T0 (sendMessage)        : reference (0 ms)")
log("summary", "T_init (system.init)    : \(ms(from: t0Date, to: marks.initAt))")
log("summary", "T_user (echo OUR uuid)  : \(ms(from: t0Date, to: marks.userEchoAt))")
log("summary", "T_pgs  (first progress) : \(ms(from: t0Date, to: marks.firstProgressAt))")
log("summary", "T_asst (first assistant): \(ms(from: t0Date, to: marks.firstAssistantAt))")
log("summary", "T_res  (result)         : \(ms(from: t0Date, to: marks.resultAt))")
log("summary", "  progress count : \(marks.progressCount)")
log("summary", "  assistant count: \(marks.assistantCount)")
log("summary", "  user msg count : \(marks.userCount)")
log("summary", "—————————————————————————————")
log("summary", "If T_user > T_asst, the queued bubble lingers past the assistant reply.")
log("summary", "If T_user > T_res,  the queued bubble lingers past turn completion.")
log("summary", "")
log("summary", "Per-label first-arrival (sorted; anything before T_user is a")
log("summary", "potential faster confirm signal):")
let sortedLabels = marks.firstByLabel.sorted { ($0.value) < ($1.value) }
for (label, when) in sortedLabels {
    let cnt = marks.countByLabel[label] ?? 0
    log("summary", "  \(ms(from: t0Date, to: when))  ×\(cnt)  \(label)")
}

session.close()
log("done", "")
