// DumpSmoke — drives one prompt through `Session` against the real CLI,
// checks the basic round-trip contract, prints per-kind message counts, and
// dumps the exported JSONL (both directions) to stderr.
//
// SMOKE_SCENARIO=single (default): one prompt, one turn. Checks that
// `start()` lists models, the prompt is replayed with its uuid, assistant
// text arrives, exactly one `.success` result names the prompt in
// `userMessageUUIDs`, the prompt's `CommandLifecycle` reaches `completed`,
// and `close()` ends the process with exit code 0.
//
// SMOKE_SCENARIO=bgjob: the model starts a background Bash
// (`run_in_background`) and replies at once; the session stays open after
// that first result (up to 30 s) to capture post-result traffic. Checks the
// job's `taskStarted` and its `taskNotification` with status `completed`.
//
//   swift run DumpSmoke
//   SMOKE_SCENARIO=bgjob swift run DumpSmoke
//
// Env: CLAUDE_BINARY_PATH, SMOKE_MODEL (default claude-haiku-4-5),
// SMOKE_PROMPT, SMOKE_SCENARIO. Work dir (kept): /tmp/ccterm-dump-<scenario>-<timestamp>/.

import AgentSDK
import Foundation

enum Scenario: String {
    case single, bgjob
}

let env = ProcessInfo.processInfo.environment
guard let scenario = Scenario(rawValue: env["SMOKE_SCENARIO"] ?? "single") else {
    FileHandle.standardError.write(Data("SMOKE_SCENARIO must be single or bgjob\n".utf8))
    exit(2)
}
let model = env["SMOKE_MODEL"] ?? "claude-haiku-4-5"
let prompt: String
switch scenario {
case .single:
    prompt = env["SMOKE_PROMPT"] ?? "Reply with exactly the two letters: ok"
case .bgjob:
    prompt =
        env["SMOKE_PROMPT"]
        ?? "Use the Bash tool with `run_in_background: true` to run `sleep 5 && echo finished`. "
        + "After kicking it off, reply with exactly the two letters: ok."
}

let workDir = URL(fileURLWithPath: "/tmp/ccterm-dump-\(scenario.rawValue)-\(Int(Date().timeIntervalSince1970))")
let exportDir = workDir.appendingPathComponent("export")
try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
}

var failures: [String] = []

func check(_ ok: Bool, _ what: String) {
    log("\(ok ? "PASS" : "FAIL")  \(what)")
    if !ok { failures.append(what) }
}

func label(_ message: Message) -> String {
    switch message {
    case .assistant: return "assistant"
    case .user(let m): return m.isReplay ? "user.replay" : m.toolResult != nil ? "user.toolResult" : "user"
    case .result(let r): return "result.\(r.subtype.rawValue)"
    case .system(let s):
        switch s {
        case .initialized: return "system.init"
        case .status: return "system.status"
        case .compactBoundary: return "system.compact_boundary"
        case .apiRetry: return "system.api_retry"
        case .thinkingTokens: return "system.thinking_tokens"
        case .taskStarted: return "system.task_started"
        case .taskProgress: return "system.task_progress"
        case .taskUpdated: return "system.task_updated"
        case .taskNotification: return "system.task_notification"
        case .backgroundTasksChanged: return "system.background_tasks_changed"
        case .permissionDenied: return "system.permission_denied"
        case .commandsChanged: return "system.commands_changed"
        case .sessionTitleChanged: return "system.session_title_changed"
        case .other(let subtype, _): return "system.other(\(subtype))"
        }
    case .streamEvent: return "stream_event"
    case .toolProgress: return "tool_progress"
    case .rateLimit: return "rate_limit_event"
    case .commandLifecycle(let c): return "command_lifecycle.\(c.state.rawValue)"
    case .promptSuggestion: return "prompt_suggestion"
    case .unknown(let raw): return "unknown(\(raw["type"]?.stringValue ?? "?"))"
    }
}

let session = Session(
    configuration: SessionConfiguration(
        workingDirectory: workDir, model: model, sessionId: UUID().uuidString.lowercased(),
        binaryPath: env["CLAUDE_BINARY_PATH"], inheritsParentEnvironment: true, messageExportDirectory: exportDir))
let input = UserInput(prompt)

var counts: [String: Int] = [:]
var replays = 0
var assistantText = ""
var results: [ResultMessage] = []
var lifecycle: [CommandLifecycle.State] = []
var startedTasks: [SystemMessage.TaskStarted] = []
var notifications: [SystemMessage.TaskNotification] = []
var termination: Termination?

func record(_ event: SessionEvent) {
    switch event {
    case .message(let message):
        counts[label(message), default: 0] += 1
        switch message {
        case .user(let m) where m.isReplay && m.uuid == input.uuid: replays += 1
        case .assistant(let m): assistantText += m.content.compactMap(\.text).joined()
        case .result(let r): results.append(r)
        case .commandLifecycle(let c) where c.commandUUID == input.uuid: lifecycle.append(c.state)
        case .system(.taskStarted(let t)):
            log("task started id=\(t.taskID) type=\(t.taskType) \(t.description)")
            startedTasks.append(t)
        case .system(.taskNotification(let n)):
            log("task notification id=\(n.taskID) status=\(n.status)")
            notifications.append(n)
        default: break
        }
    case .permissionRequest(let request):
        log("permission request tool=\(request.toolName) → allow")
        request.respond(.allow())
    case .permissionRequestCancelled(let id):
        log("permission request cancelled id=\(id)")
    case .flagSettingsChanged(let settings):
        log("flag settings changed \(settings)")
    case .exited(let t):
        termination = t
    }
}

_ = Task {
    try await Task.sleep(for: .seconds(180))
    log("FAIL  timed out after 180 s; work dir \(workDir.path)")
    exit(1)
}

log("scenario=\(scenario.rawValue) model=\(model) workDir=\(workDir.path)")
var events = session.events.makeAsyncIterator()
do {
    let initialization = try await session.start()
    check(!initialization.models.isEmpty, "start() lists models (\(initialization.models.count))")
    try session.send(input)
} catch {
    log("FAIL  start/send: \(error)")
    exit(1)
}

while results.isEmpty, let event = await events.next() { record(event) }
log("first result — counts so far: \(counts.sorted { $0.key < $1.key })")

if scenario == .bgjob {
    // Keep reading until the job reports back and the turn it triggers ends,
    // or the drain window closes the session.
    let closer = Task {
        try await Task.sleep(for: .seconds(30))
        await session.close()
    }
    var resultsAtNotification: Int?
    while let event = await events.next() {
        record(event)
        if resultsAtNotification == nil, !notifications.isEmpty { resultsAtNotification = results.count }
        if let mark = resultsAtNotification, results.count > mark { break }
    }
    closer.cancel()
}

await session.close()
while let event = await events.next() { record(event) }

log("counts: \(counts.sorted { $0.key < $1.key })")
switch scenario {
case .single:
    check(replays == 1, "prompt replayed once with its uuid (\(replays))")
    check(!assistantText.isEmpty, "assistant text arrived (\(assistantText.prefix(40).debugDescription))")
    check(results.count == 1, "exactly one result (\(results.count))")
    check(results.first?.subtype == .success, "result is success (\(results.first?.subtype.rawValue ?? "none"))")
    check(results.first?.userMessageUUIDs.contains(input.uuid) == true, "result names the prompt's uuid")
    check(lifecycle.last == .completed, "prompt lifecycle ends completed (\(lifecycle.map(\.rawValue)))")
case .bgjob:
    let job = startedTasks.first { $0.taskType == "local_bash" }
    check(job != nil, "background Bash reported taskStarted (\(startedTasks.map(\.taskType)))")
    let finished = notifications.first { $0.taskID == job?.taskID }
    check(finished?.status == "completed", "job reported taskNotification completed (\(finished?.status ?? "none"))")
}
check(termination?.exitCode == 0, "close() ends the process with exit code 0 (\(termination?.exitCode ?? -1))")

for file in (try? FileManager.default.contentsOfDirectory(at: exportDir, includingPropertiesForKeys: nil)) ?? [] {
    log("--- export \(file.path) ---")
    FileHandle.standardError.write((try? Data(contentsOf: file)) ?? Data())
}

log(failures.isEmpty ? "DumpSmoke PASS" : "DumpSmoke FAIL (\(failures.count)): \(failures.joined(separator: "; "))")
log("work dir: \(workDir.path)")
exit(failures.isEmpty ? 0 : 1)
