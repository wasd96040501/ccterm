// QueueTimingSmoke — timestamps everything the real CLI emits after a
// `Session.send` so the order of the queued → running signals is visible:
// `CommandLifecycle` queued / started, the prompt's replay (`isReplay`, same
// uuid), `system.init`, the first stream event, the first assistant block and
// the result. Streams with `includePartialMessages`, as the app does.
//
// Default: two sequential turns (the second skipped with SMOKE_SKIP_SECOND=1),
// each printed as a first-arrival table relative to its send.
// SMOKE_BACK_TO_BACK=1: two sends 5 ms apart while the CLI is idle.
// SMOKE_WHILE_RESPONDING=1: a long prompt, then two more sends 5 ms apart as
// soon as its first assistant block arrives (mid-turn, default priority).
//
// In every mode, each prompt must be replayed with its uuid, its lifecycle
// must end `completed`, and some result's `userMessageUUIDs` must name it.
// Per-mode counts (system.init, replays, results) are printed for comparison.
//
//   swift run QueueTimingSmoke
//   SMOKE_BACK_TO_BACK=1 swift run QueueTimingSmoke
//   SMOKE_WHILE_RESPONDING=1 swift run QueueTimingSmoke
//
// Env: CLAUDE_BINARY_PATH, SMOKE_MODEL (default claude-haiku-4-5), SMOKE_PROMPT,
// SMOKE_PROMPT2, SMOKE_PROMPT3, SMOKE_LONG_PROMPT, SMOKE_SKIP_SECOND,
// SMOKE_BACK_TO_BACK, SMOKE_WHILE_RESPONDING.
// Work dir (kept): /tmp/ccterm-queue-timing-<timestamp>/.

import AgentSDK
import Foundation

let env = ProcessInfo.processInfo.environment
let model = env["SMOKE_MODEL"] ?? "claude-haiku-4-5"
let prompt = env["SMOKE_PROMPT"] ?? "Write three short sentences about sunsets. No preamble."
let prompt2 = env["SMOKE_PROMPT2"] ?? "Reply with exactly: ok"
let prompt3 = env["SMOKE_PROMPT3"] ?? "Reply with exactly: done"
let longPrompt = env["SMOKE_LONG_PROMPT"] ?? "Write 8 short sentences about why the sky is blue. One per line."

let workDir = URL(fileURLWithPath: "/tmp/ccterm-queue-timing-\(Int(Date().timeIntervalSince1970))")
let exportDir = workDir.appendingPathComponent("export")
try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

var t0 = Date()

func log(_ tag: String, _ message: String) {
    let offset = String(format: "%+6.0f ms", Date().timeIntervalSince(t0) * 1000)
    FileHandle.standardError.write(Data("[\(offset)] [\(tag)] \(message)\n".utf8))
}

var failures: [String] = []

func check(_ ok: Bool, _ what: String) {
    log(ok ? "PASS" : "FAIL", what)
    if !ok { failures.append(what) }
}

let session = Session(
    configuration: SessionConfiguration(
        workingDirectory: workDir, model: model, sessionId: UUID().uuidString.lowercased(),
        binaryPath: env["CLAUDE_BINARY_PATH"], includePartialMessages: true, inheritsParentEnvironment: true,
        messageExportDirectory: exportDir))
var events = session.events.makeAsyncIterator()

/// Our prompts by uuid → display name (`#1`, …).
var names: [String: String] = [:]
var lifecycles: [String: [CommandLifecycle.State]] = [:]
var replays: [String: Int] = [:]
var results: [ResultMessage] = []
/// First arrival and count of each label within the current phase.
var firstArrival: [String: Date] = [:]
var counts: [String: Int] = [:]
var assistantBlocksInPhase = 0

func label(_ message: Message) -> String {
    switch message {
    case .assistant: return "assistant"
    case .user(let m):
        if let name = m.uuid.flatMap({ names[$0] }) { return "user.replay(\(name))" }
        return m.toolResult != nil ? "user.toolResult" : "user.other"
    case .result: return "result"
    case .system(.initialized): return "system.init"
    case .system(.status(let s)): return "system.status(\(s.status ?? "idle"))"
    case .system(.thinkingTokens): return "system.thinking_tokens"
    case .system(.other(let subtype, _)): return "system.\(subtype)"
    case .system(let s): return "system.\(String(describing: s).prefix { $0 != "(" })"
    case .streamEvent: return "stream_event"
    case .toolProgress: return "tool_progress"
    case .rateLimit: return "rate_limit_event"
    case .commandLifecycle(let c): return "lifecycle.\(c.state.rawValue)(\(names[c.commandUUID] ?? "other"))"
    case .promptSuggestion: return "prompt_suggestion"
    case .unknown(let raw): return "unknown(\(raw["type"]?.stringValue ?? "?"))"
    }
}

func record(_ event: SessionEvent) {
    guard case .message(let message) = event else {
        if case .permissionRequest(let request) = event {
            request.respond(.deny(message: "QueueTimingSmoke runs no tools"))
        }
        return
    }
    let key = label(message)
    counts[key, default: 0] += 1
    let first = firstArrival[key] == nil
    if first { firstArrival[key] = Date() }
    if first || (key != "stream_event" && key != "system.thinking_tokens") {
        log(key, "\(first ? "FIRST " : "")#\(counts[key] ?? 0)")
    }
    switch message {
    case .user(let m) where m.isReplay:
        if let uuid = m.uuid, names[uuid] != nil { replays[uuid, default: 0] += 1 }
    case .commandLifecycle(let c):
        lifecycles[c.commandUUID, default: []].append(c.state)
    case .assistant:
        assistantBlocksInPhase += 1
    case .result(let r):
        results.append(r)
    default:
        break
    }
}

func beginPhase(_ title: String) {
    t0 = Date()
    firstArrival = [:]
    counts = [:]
    assistantBlocksInPhase = 0
    log("phase", "—— \(title) ——")
}

func send(_ text: String, as name: String) -> UserInput {
    let input = UserInput(text)
    names[input.uuid] = name
    log("send", "\(name) uuid=\(input.uuid.prefix(8))")
    do {
        try session.send(input)
    } catch {
        log("FAIL", "send \(name): \(error)")
        exit(1)
    }
    return input
}

func finished(_ inputs: [UserInput]) -> Bool {
    inputs.allSatisfy { lifecycles[$0.uuid]?.last?.isTerminal == true }
}

func endPhase(_ inputs: [UserInput]) {
    log("summary", "first arrival per label:")
    for (key, when) in firstArrival.sorted(by: { $0.value < $1.value }) {
        let offset = String(format: "%+6.0f ms", when.timeIntervalSince(t0) * 1000)
        log("summary", "  \(offset)  ×\(counts[key] ?? 0)  \(key)")
    }
    let replayCount = counts.filter { $0.key.hasPrefix("user.replay") }.values.reduce(0, +)
    log(
        "summary",
        "system.init=\(counts["system.init"] ?? 0) replays=\(replayCount) "
            + "assistant=\(counts["assistant"] ?? 0) result=\(counts["result"] ?? 0)")
    for input in inputs {
        let name = names[input.uuid] ?? "?"
        let states = lifecycles[input.uuid] ?? []
        check(replays[input.uuid] == 1, "\(name) replayed once with its uuid (\(replays[input.uuid] ?? 0))")
        check(states.last == .completed, "\(name) lifecycle ends completed (\(states.map(\.rawValue)))")
        check(results.contains { $0.userMessageUUIDs.contains(input.uuid) }, "a result names \(name)'s uuid")
    }
}

_ = Task {
    try await Task.sleep(for: .seconds(300))
    log("FAIL", "timed out after 300 s; work dir \(workDir.path)")
    exit(1)
}

log("setup", "model=\(model) workDir=\(workDir.path)")
do {
    try await session.start()
} catch {
    log("FAIL", "start: \(error)")
    exit(1)
}

if env["SMOKE_WHILE_RESPONDING"] == "1" {
    beginPhase("while responding: #1, then #2 and #3 after its first assistant block")
    let first = send(longPrompt, as: "#1")
    while assistantBlocksInPhase == 0, !finished([first]), let event = await events.next() { record(event) }
    let second = send(prompt2, as: "#2")
    try await Task.sleep(for: .milliseconds(5))
    let third = send(prompt3, as: "#3")
    while !finished([first, second, third]), let event = await events.next() { record(event) }
    endPhase([first, second, third])
} else if env["SMOKE_BACK_TO_BACK"] == "1" {
    beginPhase("back to back: #1 and #2 5 ms apart")
    let first = send(prompt, as: "#1")
    try await Task.sleep(for: .milliseconds(5))
    let second = send(prompt2, as: "#2")
    while !finished([first, second]), let event = await events.next() { record(event) }
    endPhase([first, second])
} else {
    beginPhase("turn 1")
    let first = send(prompt, as: "#1")
    while !finished([first]), let event = await events.next() { record(event) }
    endPhase([first])
    if env["SMOKE_SKIP_SECOND"] == nil {
        beginPhase("turn 2")
        let second = send(prompt2, as: "#2")
        while !finished([second]), let event = await events.next() { record(event) }
        endPhase([second])
    }
}

await session.close()
log(
    "done",
    failures.isEmpty
        ? "QueueTimingSmoke PASS"
        : "QueueTimingSmoke FAIL (\(failures.count)): \(failures.joined(separator: "; "))")
log("done", "work dir: \(workDir.path)")
exit(failures.isEmpty ? 0 : 1)
