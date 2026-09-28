// ThinkingUsageSmoke — traces token usage across one streamed turn with
// extended thinking against the real CLI, so the ground-truth usage shape is
// visible, and checks the parts a usage display relies on.
//
// Per API response (`messageID`) it prints: the `message_start` usage (real
// input, placeholder output), every `message_delta` output count (the
// authoritative output total, thinking included), thinking vs. text delta
// counts and characters, the `system.thinking_tokens` estimates, and the
// finished `AssistantMessage` usage. Then the turn's sum of authoritative
// input (cache excluded) and output, and the result's usage, cost and
// per-model usage. Checks:
//   - the model thought (thinking blocks, deltas or `thinking_tokens`);
//   - every response has a `message_start` usage with input and a
//     `message_delta` with a positive output count;
//   - the summed `message_delta` output equals `ResultMessage.usage`'s;
//   - the turn succeeds with a positive cost and per-model usage.
//
//   swift run ThinkingUsageSmoke
//
// Env: CLAUDE_BINARY_PATH, SMOKE_MODEL (default claude-haiku-4-5), SMOKE_PROMPT
// (default: a puzzle that needs thought), SMOKE_EFFORT (optional `--effort`),
// SMOKE_THINKING_TOKENS (thinking budget, default 8000), SMOKE_TIMEOUT
// (seconds, default 240). Work dir (kept): /tmp/ccterm-thinking-usage-<timestamp>/.

import AgentSDK
import Foundation

let env = ProcessInfo.processInfo.environment
let model = env["SMOKE_MODEL"] ?? "claude-haiku-4-5"
let effort = env["SMOKE_EFFORT"].flatMap(Effort.init(rawValue:))
let thinkingBudget = Int(env["SMOKE_THINKING_TOKENS"] ?? "") ?? 8000
let timeoutSeconds = Int(env["SMOKE_TIMEOUT"] ?? "") ?? 240
let prompt =
    env["SMOKE_PROMPT"]
    ?? "Solve this step by step, thinking carefully before you answer. I'm thinking of a three-digit number. "
    + "All three digits are different. The number is a perfect square. The sum of its digits is also a perfect "
    + "square. When you reverse its digits you get a different three-digit perfect square. What is the number? "
    + "Explain briefly how you found it."

let workDir = URL(fileURLWithPath: "/tmp/ccterm-thinking-usage-\(Int(Date().timeIntervalSince1970))")
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

/// What one API response reported about its usage.
struct Response {
    var start: Usage?
    var deltaOutputs: [Int] = []
    var stopReason: String?
    var thinkingBlocks = 0
    var thinkingDeltas = 0
    var thinkingChars = 0
    var signatureDeltas = 0
    var textDeltas = 0
    var textChars = 0
    var thinkingEstimates: [Int] = []
    var finished: Usage?

    /// The last `message_delta` count wins; the finished block's is a fallback.
    var output: Int { deltaOutputs.last ?? finished?.outputTokens ?? 0 }
    var input: Int { finished?.inputTokens ?? start?.inputTokens ?? 0 }
}

let session = Session(
    configuration: SessionConfiguration(
        workingDirectory: workDir, model: model, sessionId: UUID().uuidString.lowercased(),
        binaryPath: env["CLAUDE_BINARY_PATH"], thinking: .enabled(budgetTokens: thinkingBudget), effort: effort,
        includePartialMessages: true, inheritsParentEnvironment: true, messageExportDirectory: exportDir))

var order: [String] = []
var responses: [String: Response] = [:]
var result: ResultMessage?

func update(_ id: String?, _ change: (inout Response) -> Void) {
    guard let id else { return }
    if responses[id] == nil { order.append(id) }
    change(&responses[id, default: Response()])
}

func record(_ event: SessionEvent) {
    switch event {
    case .message(.streamEvent(let e)):
        switch e.event {
        case .messageStart(let id, _, let usage):
            update(id) { $0.start = usage }
        case .contentBlockStart(_, .thinking), .contentBlockStart(_, .redactedThinking):
            update(order.last) { $0.thinkingBlocks += 1 }
        case .contentBlockDelta(_, .thinking(let text)):
            update(order.last) {
                $0.thinkingDeltas += 1
                $0.thinkingChars += text.count
            }
        case .contentBlockDelta(_, .text(let text)):
            update(order.last) {
                $0.textDeltas += 1
                $0.textChars += text.count
            }
        case .contentBlockDelta(_, .signature):
            update(order.last) { $0.signatureDeltas += 1 }
        case .messageDelta(let stopReason, let usage):
            update(order.last) {
                if let output = usage?.outputTokens { $0.deltaOutputs.append(output) }
                $0.stopReason = stopReason ?? $0.stopReason
            }
        default:
            break
        }
    case .message(.system(.thinkingTokens(let t))):
        update(order.last) { $0.thinkingEstimates.append(t.estimatedTokens) }
    case .message(.assistant(let m)):
        update(m.messageID) { $0.finished = m.usage ?? $0.finished }
    case .message(.result(let r)):
        result = r
    case .permissionRequest(let request):
        request.respond(.deny(message: "ThinkingUsageSmoke runs no tools"))
    default:
        break
    }
}

func describe(_ usage: Usage?) -> String {
    guard let u = usage else { return "—" }
    return "in=\(u.inputTokens) out=\(u.outputTokens) cacheCreate=\(u.cacheCreationInputTokens) "
        + "cacheRead=\(u.cacheReadInputTokens)"
}

_ = Task {
    try await Task.sleep(for: .seconds(timeoutSeconds))
    log("FAIL  timed out after \(timeoutSeconds) s; work dir \(workDir.path)")
    exit(1)
}

log(
    "model=\(model) effort=\(effort?.rawValue ?? "default") thinkingBudget=\(thinkingBudget) "
        + "workDir=\(workDir.path)")
var events = session.events.makeAsyncIterator()
do {
    try await session.start()
    try session.send(UserInput(prompt))
} catch {
    log("FAIL  start/send: \(error)")
    exit(1)
}
while result == nil, let event = await events.next() { record(event) }
await session.close()
while let event = await events.next() { record(event) }

for (i, id) in order.enumerated() {
    guard let r = responses[id] else { continue }
    log("── response #\(i + 1) \(id)")
    log("  message_start usage : \(describe(r.start))  (output is a placeholder)")
    log("  message_delta output: \(r.deltaOutputs)  stop_reason=\(r.stopReason ?? "nil")")
    log(
        "  thinking            : blocks=\(r.thinkingBlocks) deltas=\(r.thinkingDeltas) chars=\(r.thinkingChars) "
            + "signatures=\(r.signatureDeltas)")
    log("  thinking_tokens est : \(r.thinkingEstimates)")
    log("  text                : deltas=\(r.textDeltas) chars=\(r.textChars)")
    log("  finished usage      : \(describe(r.finished))")
    log("  → authoritative     : input=\(r.input) output=\(r.output)")
}
let all = order.compactMap { responses[$0] }
let turnInput = all.reduce(0) { $0 + $1.input }
let turnOutput = all.reduce(0) { $0 + $1.output }
log("turn (no estimation): ↑\(turnInput) ↓\(turnOutput)")
if let result {
    log("result usage: \(describe(result.usage))")
    log("result cost=$\(String(format: "%.5f", result.totalCostUSD)) turns=\(result.numTurns) ms=\(result.durationMS)")
    for (name, u) in result.modelUsage.sorted(by: { $0.key < $1.key }) {
        log(
            "  \(name): in=\(u.inputTokens) out=\(u.outputTokens) cacheCreate=\(u.cacheCreationInputTokens) "
                + "cacheRead=\(u.cacheReadInputTokens) cost=$\(String(format: "%.5f", u.costUSD)) "
                + "window=\(u.contextWindow)")
    }
}

let thought = all.contains { $0.thinkingBlocks > 0 || $0.thinkingDeltas > 0 || !$0.thinkingEstimates.isEmpty }
check(thought, "the model thought (raise SMOKE_THINKING_TOKENS or set SMOKE_EFFORT if not)")
check(!all.isEmpty && all.allSatisfy { ($0.start?.totalInputTokens ?? 0) > 0 }, "every response has start input")
check(!all.isEmpty && all.allSatisfy { ($0.deltaOutputs.last ?? 0) > 0 }, "every response has a delta output")
check(
    turnOutput == result?.usage.outputTokens,
    "summed message_delta output equals the result's (\(turnOutput) vs \(result?.usage.outputTokens ?? -1))")
check(result?.subtype == .success, "turn succeeds (\(result?.subtype.rawValue ?? "no result"))")
check((result?.totalCostUSD ?? 0) > 0 && result?.modelUsage.isEmpty == false, "result reports cost and model usage")

log(
    failures.isEmpty
        ? "ThinkingUsageSmoke PASS"
        : "ThinkingUsageSmoke FAIL (\(failures.count)): \(failures.joined(separator: "; "))")
log("work dir: \(workDir.path)")
exit(failures.isEmpty ? 0 : 1)
