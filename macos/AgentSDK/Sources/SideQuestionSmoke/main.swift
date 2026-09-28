// SideQuestionSmoke — checks `Session.askSideQuestion` (the `side_question`
// control request behind `/btw`) against the real CLI.
//
// Runs in plan mode so the model cannot use tools. A seed turn plants a
// secret in the conversation; then the side question asks for it. Checks:
//   - the answer recalls the secret, which only the shared conversation
//     holds (it is not re-sent), so the CLI answered from its own history;
//   - the answer is a real model answer (`synthetic == false`);
//   - the side question does not advance the main loop (no new result).
// The wait for the answer is bounded by SMOKE_TIMEOUT_SECONDS by cancelling
// the call, which withdraws the request.
//
//   swift run SideQuestionSmoke
//
// Env: CLAUDE_BINARY_PATH, SMOKE_MODEL (default claude-haiku-4-5),
// SMOKE_TIMEOUT_SECONDS (default 60). Work dir (kept): /tmp/ccterm-side-question-<timestamp>/.

import AgentSDK
import Foundation

let secret = "PURPLE-RHINO-7"
let env = ProcessInfo.processInfo.environment
let model = env["SMOKE_MODEL"] ?? "claude-haiku-4-5"
let timeoutSeconds = Int(env["SMOKE_TIMEOUT_SECONDS"] ?? "") ?? 60

let workDir = URL(fileURLWithPath: "/tmp/ccterm-side-question-\(Int(Date().timeIntervalSince1970))")
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
        workingDirectory: workDir, model: model, permissionMode: .plan, sessionId: UUID().uuidString.lowercased(),
        binaryPath: env["CLAUDE_BINARY_PATH"],
        systemPrompt: .custom("You are a smoke harness. Answer briefly. Do nothing on your own."),
        inheritsParentEnvironment: true, messageExportDirectory: exportDir))

var results = 0

func record(_ event: SessionEvent) {
    switch event {
    case .message(.assistant(let m)):
        let text = m.content.compactMap(\.text).joined()
        if !text.isEmpty { log("assistant \(text.prefix(60).debugDescription)") }
    case .message(.result(let r)):
        results += 1
        log("result #\(results) \(r.subtype.rawValue)")
    case .permissionRequest(let request):
        request.respond(.deny(message: "SideQuestionSmoke runs no tools"))
    default:
        break
    }
}

_ = Task {
    try await Task.sleep(for: .seconds(timeoutSeconds * 2 + 30))
    log("FAIL  timed out; work dir \(workDir.path)")
    exit(1)
}

log("model=\(model) workDir=\(workDir.path)")
var events = session.events.makeAsyncIterator()
do {
    try await session.start()
    try session.send(UserInput("Remember this for our conversation: the launch code is \(secret). Reply with only: ok"))
} catch {
    log("FAIL  start/send: \(error)")
    exit(1)
}
while results == 0, let event = await events.next() { record(event) }

// Keep consuming events while the side question is outstanding.
let consumer = Task { [events] in
    var rest = events
    while let event = await rest.next() { record(event) }
}
let ask = Task {
    try await session.askSideQuestion("What launch code did I just tell you? Answer with ONLY the code, nothing else.")
}
let timer = Task {
    try await Task.sleep(for: .seconds(timeoutSeconds))
    ask.cancel()
}
let outcome = await ask.result
timer.cancel()

switch outcome {
case .success(let answer?):
    log("side answer \(answer.response.prefix(120).debugDescription) synthetic=\(answer.synthetic)")
    check(answer.response.contains(secret), "the answer recalls the secret from the shared conversation")
    check(!answer.synthetic, "the answer is a real model answer")
case .success(nil):
    check(false, "the side question produced text")
case .failure(let error as CancellationError):
    check(false, "the side question answered within \(timeoutSeconds) s (\(error))")
case .failure(let error):
    check(false, "the side question succeeded (\(error))")
}

await session.close()
await consumer.value
check(results == 1, "the side question added no turn result (\(results) results)")

log(
    failures.isEmpty
        ? "SideQuestionSmoke PASS" : "SideQuestionSmoke FAIL (\(failures.count)): \(failures.joined(separator: "; "))")
log("work dir: \(workDir.path)")
exit(failures.isEmpty ? 0 : 1)
