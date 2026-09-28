// ContextUsageSmoke — checks `Session.contextUsage()` (the
// `get_context_usage` control request) against the real CLI.
//
// Runs in plan mode so the model cannot use tools. Checks:
//   - before any turn, the response decodes with a positive window
//     (`rawMaxTokens`, `maxTokens`), a positive total and named categories;
//   - cancelling an in-flight call throws `CancellationError`, and the next
//     call still succeeds (the withdrawn request does not wedge the session);
//   - after one short turn the total has grown and `apiUsage` is present.
// Each call is bounded by SMOKE_TIMEOUT_SECONDS by cancelling it.
//
//   swift run ContextUsageSmoke
//
// Env: CLAUDE_BINARY_PATH, SMOKE_MODEL (default claude-haiku-4-5), SMOKE_PROMPT
// (the turn; default a one-word reply), SMOKE_TIMEOUT_SECONDS (default 10).
// Work dir (kept): /tmp/ccterm-context-usage-<timestamp>/.

import AgentSDK
import Foundation

let env = ProcessInfo.processInfo.environment
let model = env["SMOKE_MODEL"] ?? "claude-haiku-4-5"
let prompt = env["SMOKE_PROMPT"] ?? "Reply with exactly the two letters: ok"
let timeoutSeconds = Int(env["SMOKE_TIMEOUT_SECONDS"] ?? "") ?? 10

let workDir = URL(fileURLWithPath: "/tmp/ccterm-context-usage-\(Int(Date().timeIntervalSince1970))")
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
        binaryPath: env["CLAUDE_BINARY_PATH"], systemPrompt: .custom("You are a smoke harness. Answer briefly."),
        inheritsParentEnvironment: true, messageExportDirectory: exportDir))

/// One `contextUsage()` call, cancelled after `timeoutSeconds`.
func probe(_ name: String) async -> ContextUsage? {
    let call = Task { try await session.contextUsage() }
    let timer = Task {
        try await Task.sleep(for: .seconds(timeoutSeconds))
        call.cancel()
    }
    defer { timer.cancel() }
    switch await call.result {
    case .success(let usage):
        log(
            "[\(name)] total=\(usage.totalTokens) max=\(usage.maxTokens) rawMax=\(usage.rawMaxTokens) "
                + "\(usage.percentage)% model=\(usage.model ?? "nil") categories=\(usage.categories.count) "
                + "memoryFiles=\(usage.memoryFiles.count) mcpTools=\(usage.mcpTools.count) "
                + "apiUsage=\(usage.apiUsage.map { "in=\($0.totalInputTokens) out=\($0.outputTokens)" } ?? "nil")")
        for category in usage.categories.prefix(6) {
            log("[\(name)]   \(category.name): \(category.tokens)\(category.isDeferred ? " (deferred)" : "")")
        }
        return usage
    case .failure(let error):
        check(false, "\(name): contextUsage() answered within \(timeoutSeconds) s (\(error))")
        return nil
    }
}

_ = Task {
    try await Task.sleep(for: .seconds(180))
    log("FAIL  timed out after 180 s; work dir \(workDir.path)")
    exit(1)
}

log("model=\(model) workDir=\(workDir.path)")
var events = session.events.makeAsyncIterator()
do {
    try await session.start()
} catch {
    log("FAIL  start: \(error)")
    exit(1)
}

let fresh = await probe("fresh")
if let fresh {
    check(fresh.rawMaxTokens > 0 && fresh.maxTokens > 0, "the window is positive")
    check(fresh.totalTokens > 0, "the fresh session already spends tokens (system prompt, tools)")
    check(!fresh.categories.isEmpty && fresh.categories.allSatisfy { !$0.name.isEmpty }, "categories are named")
}

let cancelled = Task { try await session.contextUsage() }
try await Task.sleep(for: .milliseconds(5))
cancelled.cancel()
switch await cancelled.result {
case .failure(let error): check(error is CancellationError, "a cancelled call throws CancellationError (\(error))")
case .success: check(false, "a cancelled call throws CancellationError (it answered first)")
}
check(await probe("after cancel") != nil, "the next call still succeeds")

do {
    try session.send(UserInput(prompt))
} catch {
    log("FAIL  send: \(error)")
    exit(1)
}
var result: ResultMessage?
while result == nil, let event = await events.next() {
    switch event {
    case .message(.result(let r)): result = r
    case .permissionRequest(let request): request.respond(.deny(message: "ContextUsageSmoke runs no tools"))
    default: break
    }
}
check(result?.subtype == .success, "the turn succeeds (\(result?.subtype.rawValue ?? "no result"))")
if let afterTurn = await probe("after turn") {
    check(afterTurn.totalTokens > fresh?.totalTokens ?? 0, "the total grows after a turn")
    check(afterTurn.apiUsage != nil, "apiUsage is present after a turn")
}

await session.close()
log(
    failures.isEmpty
        ? "ContextUsageSmoke PASS" : "ContextUsageSmoke FAIL (\(failures.count)): \(failures.joined(separator: "; "))")
log("work dir: \(workDir.path)")
exit(failures.isEmpty ? 0 : 1)
