// InterruptSmoke — interrupts a streaming turn with `Session.interrupt()`
// against the real CLI and checks what the transcript receives afterwards.
//
// Streams (`includePartialMessages`) a long-running prompt with a known uuid,
// calls `interrupt()` INTERRUPT_AFTER_MS after the first text delta so it
// lands mid-stream, reads until the turn's result, then sends a short
// follow-up. Checks:
//   - `interrupt()` is acknowledged, the turn ends interrupted
//     (`terminalReason` `aborted_streaming`), and the partial text block is
//     flushed with `isAborted`;
//   - the prompt is replayed exactly once with its uuid — a second echo is
//     the "interrupt duplicates the user message" bug (exit code 2);
//   - the prompt's `CommandLifecycle` ends `cancelled`;
//   - the session stays usable: the follow-up turn ends `.success`;
//   - `close()` ends the process with exit code 0.
// Also reports synthetic "[Request interrupted by user]" messages and user
// messages carrying a `parentToolUseID`.
//
//   swift run InterruptSmoke
//
// Env: CLAUDE_BINARY_PATH, SMOKE_MODEL (default claude-haiku-4-5),
// SMOKE_PROMPT (default: a long story), INTERRUPT_AFTER_MS (default 1500).
// Work dir (kept): /tmp/ccterm-interrupt-<timestamp>/.

import AgentSDK
import Foundation

let env = ProcessInfo.processInfo.environment
let model = env["SMOKE_MODEL"] ?? "claude-haiku-4-5"
let prompt =
    env["SMOKE_PROMPT"]
    ?? "Write a long bedtime story about a robot exploring Mars. Aim for at least 800 words. "
    + "Take your time and be descriptive."
let interruptAfterMS = Int(env["INTERRUPT_AFTER_MS"] ?? "") ?? 1500

let workDir = URL(fileURLWithPath: "/tmp/ccterm-interrupt-\(Int(Date().timeIntervalSince1970))")
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

let session = Session(
    configuration: SessionConfiguration(
        workingDirectory: workDir, model: model, sessionId: UUID().uuidString.lowercased(),
        binaryPath: env["CLAUDE_BINARY_PATH"], includePartialMessages: true, inheritsParentEnvironment: true,
        messageExportDirectory: exportDir))
let input = UserInput(prompt)
let followUp = UserInput("Reply with exactly the two letters: ok")

var assistantCount = 0
var abortedBlocks = 0
var echoes = 0
var interruptNotices = 0
var otherUserMessages = 0
var subagentUserMessages = 0
var lifecycle: [CommandLifecycle.State] = []
var results: [ResultMessage] = []
var firstTextDelta: Date?
var interruptSent = false
var interruptAcked = false
var termination: Termination?

func record(_ event: SessionEvent) {
    switch event {
    case .message(.assistant(let m)):
        assistantCount += 1
        if m.isAborted { abortedBlocks += 1 }
        let text = m.content.compactMap(\.text).joined()
        log("assistant #\(assistantCount) aborted=\(m.isAborted) text=\(text.prefix(40).debugDescription)")
    case .message(.user(let m)):
        let text = m.content.compactMap(\.text).joined(separator: "|")
        if m.parentToolUseID != nil { subagentUserMessages += 1 }
        if m.uuid == input.uuid {
            echoes += 1
        } else if text.contains("[Request interrupted by user") {
            interruptNotices += 1
        } else if m.toolResult == nil && m.uuid != followUp.uuid {
            otherUserMessages += 1
        }
        log("user uuid=\(m.uuid?.prefix(8) ?? "nil") replay=\(m.isReplay) text=\(text.prefix(60).debugDescription)")
    case .message(.streamEvent(let e)):
        if firstTextDelta == nil, case .contentBlockDelta(_, .text) = e.event {
            firstTextDelta = Date()
            log("first text delta")
        }
    case .message(.commandLifecycle(let c)) where c.commandUUID == input.uuid:
        lifecycle.append(c.state)
    case .message(.result(let r)):
        log("result subtype=\(r.subtype.rawValue) terminalReason=\(r.terminalReason ?? "nil")")
        results.append(r)
    case .permissionRequest(let request):
        log("permission request tool=\(request.toolName) → deny")
        request.respond(.deny(message: "InterruptSmoke runs no tools"))
    case .exited(let t):
        termination = t
    default:
        break
    }
}

_ = Task {
    try await Task.sleep(for: .seconds(180))
    log("FAIL  timed out after 180 s; work dir \(workDir.path)")
    exit(1)
}

log("model=\(model) interruptAfterMS=\(interruptAfterMS) workDir=\(workDir.path)")
var events = session.events.makeAsyncIterator()
do {
    try await session.start()
    try session.send(input)
} catch {
    log("FAIL  start/send: \(error)")
    exit(1)
}

while firstTextDelta == nil, results.isEmpty, let event = await events.next() { record(event) }
let interrupter = Task {
    try await Task.sleep(for: .milliseconds(interruptAfterMS))
    log("calling interrupt()")
    interruptSent = true
    try await session.interrupt()
    interruptAcked = true
    log("interrupt acknowledged")
}

while results.isEmpty, let event = await events.next() { record(event) }
guard interruptSent else {
    log("FAIL  the turn finished before the interrupt fired; lower INTERRUPT_AFTER_MS")
    exit(1)
}
if case .failure(let error) = await interrupter.result { log("interrupt() threw: \(error)") }
check(interruptAcked, "interrupt() acknowledged")
let interrupted = results.first
check(
    interrupted?.terminalReason?.hasPrefix("aborted") == true,
    "turn ends interrupted (\(interrupted?.subtype.rawValue ?? "none"), \(interrupted?.terminalReason ?? "nil"))")
check(abortedBlocks > 0, "the partial text block is flushed with isAborted (\(abortedBlocks))")

try? session.send(followUp)
while results.count < 2, let event = await events.next() { record(event) }
check(results.dropFirst().first?.subtype == .success, "follow-up turn after the interrupt succeeds")

await session.close()
while let event = await events.next() { record(event) }

check(lifecycle.last == .cancelled, "prompt lifecycle ends cancelled (\(lifecycle.map(\.rawValue)))")
check(termination?.exitCode == 0, "close() ends the process with exit code 0 (\(termination?.exitCode ?? -1))")
log(
    "assistant=\(assistantCount) interruptNotices=\(interruptNotices) "
        + "otherUserMessages=\(otherUserMessages) subagentUserMessages=\(subagentUserMessages)")

if echoes > 1 {
    log("REPRODUCED: the CLI echoed the prompt \(echoes) times after the interrupt; work dir \(workDir.path)")
    exit(2)
}
check(echoes == 1, "prompt echoed exactly once (\(echoes))")

log(
    failures.isEmpty
        ? "InterruptSmoke PASS" : "InterruptSmoke FAIL (\(failures.count)): \(failures.joined(separator: "; "))")
log("work dir: \(workDir.path)")
exit(failures.isEmpty ? 0 : 1)
