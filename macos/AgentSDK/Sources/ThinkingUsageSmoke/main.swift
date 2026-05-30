import AgentSDK
import Foundation

// Smoke for the #249 streaming-token-usage flow, run against a REAL `claude`
// subprocess with the strongest (default) model and extended thinking on.
//
// Goal: capture the GROUND-TRUTH token-usage shape across one full turn so we
// know exactly what the no-estimation pill can show. It traces, per assistant
// message:
//
//   • `message_start` usage  — real `input_tokens` + the `output_tokens`
//     placeholder (the thing the deleted estimator existed to paper over).
//   • `message_delta` usage  — the authoritative cumulative `output_tokens`
//     (the single point where the real output total lands).
//   • thinking vs. text char split — so we can see that `output_tokens`
//     accounts for thinking the model never renders.
//   • the finalized `.assistant` envelope usage (input/output/cache).
//   • the `.result` envelope — total usage, per-model usage, cost, turns,
//     duration.
//
// It also recomputes "turn usage (no estimation)" exactly the way the app now
// does — sum over assistant messages of authoritative (input + output),
// cache excluded — so the printed number is what the running pill would read.
//
// Run from `macos/AgentSDK`:
//
//   swift run ThinkingUsageSmoke
//
// Env:
//   CLAUDE_BINARY_PATH    — override claude binary lookup
//   SMOKE_MODEL           — default: omitted → CLI default (strongest, Opus)
//   SMOKE_EFFORT          — default: xhigh (matches the app's default-model effort)
//   SMOKE_THINKING_TOKENS — optional: set --max-thinking-tokens explicitly
//   SMOKE_PROMPT          — default: a reasoning puzzle that triggers thinking
//   SMOKE_TIMEOUT         — result wait seconds (default 240)

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

let env = ProcessInfo.processInfo.environment

// nil model => the CLI default, which is the strongest model the account has.
let model: String? = {
    guard let m = env["SMOKE_MODEL"], !m.isEmpty else { return nil }
    return m
}()
let effort: Effort? = {
    let raw = env["SMOKE_EFFORT"] ?? "xhigh"
    return raw.isEmpty ? nil : Effort(rawValue: raw)
}()
let thinkingTokens: Int? = env["SMOKE_THINKING_TOKENS"].flatMap(Int.init)
let prompt =
    env["SMOKE_PROMPT"]
    ?? ("Solve this step by step, thinking carefully before you answer. "
        + "I'm thinking of a three-digit number. All three digits are different. "
        + "The number is a perfect square. The sum of its digits is also a perfect "
        + "square. When you reverse its digits you get a different three-digit "
        + "perfect square. What is the number? Explain how you found it.")
let timeoutSec = Double(env["SMOKE_TIMEOUT"] ?? "") ?? 240

guard let claudeBin = locateClaude() else {
    log("ERROR: no claude binary found (set CLAUDE_BINARY_PATH)")
    exit(1)
}

let stamp = Int(Date().timeIntervalSince1970)
let workDir = URL(fileURLWithPath: "/tmp/ccterm-thinking-smoke-\(stamp)", isDirectory: true)
let exportDir = workDir.appendingPathComponent("export", isDirectory: true)
try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

let sessionId = UUID().uuidString.lowercased()
log("workDir=\(workDir.path)")
log(
    "sessionId=\(sessionId) model=\(model ?? "(CLI default)") effort=\(effort?.rawValue ?? "(none)") "
        + "maxThinkingTokens=\(thinkingTokens.map(String.init) ?? "(none)")")

let config = SessionConfiguration(
    workingDirectory: workDir,
    model: model,
    sessionId: sessionId,
    binaryPath: claudeBin,
    maxThinkingTokens: thinkingTokens,
    effort: effort,
    // Match the app: opt into SSE-style partial messages so usage ticks in
    // live on `onStreamEvent`.
    includePartialMessages: true,
    inheritsParentEnvironment: true,
    allowDangerouslySkipPermissions: true,
    messageExportDirectory: exportDir
)

let session = AgentSDK.Session(configuration: config)
session.lastKnownSessionId = sessionId

// MARK: - Per-message accounting

final class MsgRecord: @unchecked Sendable {
    let id: String
    var startInput: Int?
    var startOutput: Int?  // placeholder, NOT the real total
    var startCacheCreation: Int?
    var startCacheRead: Int?
    var deltaOutputs: [Int] = []  // every message_delta output_tokens (cumulative)
    var deltaStopReason: String?
    var deltaThinkingTokens: Int?  // message_delta output_tokens_details.thinking_tokens
    // The thinking text is redacted in the stream (thinking_delta.thinking == "").
    // Per the CLI's own schema, `thinking_delta.estimated_tokens` is the PER-FRAME
    // INCREMENT, not a running total — the CLI accumulates it and re-emits a
    // `system.thinking_tokens` carrying the cumulative `estimated_tokens` plus the
    // per-frame `estimated_tokens_delta`.
    var thinkingDeltaCount = 0
    var thinkingChars = 0  // expected ~0 (redacted)
    var thinkingDeltaIncrements: [Int] = []  // thinking_delta.estimated_tokens (per-frame delta)
    var thinkingCumulativeSeries: [Int] = []  // system.thinking_tokens.estimated_tokens (running total)
    var thinkingDeltaFromSystem: [Int] = []  // system.thinking_tokens.estimated_tokens_delta
    var signatureDeltaCount = 0
    var textDeltaCount = 0
    var textChars = 0
    var finalInput: Int?
    var finalOutput: Int?
    var finalCacheCreation: Int?
    var finalCacheRead: Int?
    init(id: String) { self.id = id }

    /// Authoritative output for this message: last message_delta wins, else the
    /// finalized envelope, else the placeholder.
    var authoritativeOutput: Int { deltaOutputs.last ?? finalOutput ?? startOutput ?? 0 }
    /// Authoritative input (cache excluded): finalized envelope wins, else start.
    var authoritativeInput: Int { finalInput ?? startInput ?? 0 }
}

final class Tally: @unchecked Sendable {
    var order: [String] = []
    var byId: [String: MsgRecord] = [:]
    var rawStartUsageDumps: [String] = []
    var rawDeltaUsageDumps: [String] = []
    var firstThinkingSnippet: String?
    var firstTextSnippet: String?

    func record(_ id: String) -> MsgRecord {
        if let r = byId[id] { return r }
        let r = MsgRecord(id: id)
        byId[id] = r
        order.append(id)
        return r
    }
}
let tally = Tally()

func intOf(_ d: [String: Any]?, _ key: String) -> Int? {
    (d?[key] as? NSNumber)?.intValue
}
func prettyJSON(_ obj: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
        let s = String(data: data, encoding: .utf8)
    else { return "\(obj)" }
    return s
}

let resultSeen = DispatchSemaphore(value: 0)
var resultFired = false

// MARK: - Stream-event path (live usage)

session.onStreamEvent = { (evt: Message2StreamEvent) in
    switch evt.event {
    case .messageStart(let s):
        guard let msg = s.message, let id = msg["id"] as? String else { return }
        let rec = tally.record(id)
        let usage = msg["usage"] as? [String: Any]
        rec.startInput = intOf(usage, "input_tokens")
        rec.startOutput = intOf(usage, "output_tokens")
        rec.startCacheCreation = intOf(usage, "cache_creation_input_tokens")
        rec.startCacheRead = intOf(usage, "cache_read_input_tokens")
        if let usage, tally.rawStartUsageDumps.count < 2 {
            tally.rawStartUsageDumps.append(prettyJSON(usage))
        }

    case .contentBlockDelta(let d):
        guard let id = tally.order.last, let delta = d.delta else { return }
        let rec = tally.record(id)
        switch delta["type"] as? String {
        case "text_delta":
            let t = (delta["text"] as? String) ?? ""
            rec.textDeltaCount += 1
            rec.textChars += t.count
            if tally.firstTextSnippet == nil, !t.isEmpty {
                tally.firstTextSnippet = String(t.prefix(80))
            }
        case "thinking_delta":
            // The thinking TEXT is redacted (empty); the API carries a running
            // `estimated_tokens` instead.
            let t = (delta["thinking"] as? String) ?? ""
            rec.thinkingDeltaCount += 1
            rec.thinkingChars += t.count
            if let est = intOf(delta, "estimated_tokens") { rec.thinkingDeltaIncrements.append(est) }
            if tally.firstThinkingSnippet == nil, !t.isEmpty {
                tally.firstThinkingSnippet = String(t.prefix(80))
            }
        case "signature_delta":
            rec.signatureDeltaCount += 1
        default:
            break
        }

    case .messageDelta(let d):
        guard let id = tally.order.last else { return }
        let rec = tally.record(id)
        if let out = intOf(d.usage, "output_tokens") { rec.deltaOutputs.append(out) }
        if let details = d.usage?["output_tokens_details"] as? [String: Any] {
            rec.deltaThinkingTokens = intOf(details, "thinking_tokens")
        }
        if let stop = (d.delta?["stop_reason"] as? String) { rec.deltaStopReason = stop }
        if let usage = d.usage, tally.rawDeltaUsageDumps.count < 2 {
            tally.rawDeltaUsageDumps.append(prettyJSON(usage))
        }

    default:
        break
    }
}

// MARK: - Finalized onMessage path (authoritative reconciliation + result)

final class ResultBox: @unchecked Sendable {
    var totalInput: Int?
    var totalOutput: Int?
    var totalCacheCreation: Int?
    var totalCacheRead: Int?
    var costUsd: Double?
    var numTurns: Int?
    var durationMs: Int?
    var modelUsageDump: String?
}
let resultBox = ResultBox()

session.onMessage = { (msg: Message2) in
    switch msg {
    case .assistant(let a):
        guard let id = a.message?.id else { return }
        let rec = tally.record(id)
        rec.finalInput = a.message?.usage?.inputTokens
        rec.finalOutput = a.message?.usage?.outputTokens
        rec.finalCacheCreation = a.message?.usage?.cacheCreationInputTokens
        rec.finalCacheRead = a.message?.usage?.cacheReadInputTokens
    case .system(.thinkingTokens(let tt)):
        // The CLI synthesizes `system.thinking_tokens` from the redacted
        // thinking_delta stream. `estimatedTokens` = cumulative running total,
        // `estimatedTokensDelta` = the per-frame increment.
        guard let id = tally.order.last else { return }
        let rec = tally.record(id)
        if let cum = tt.estimatedTokens { rec.thinkingCumulativeSeries.append(cum) }
        if let d = tt.estimatedTokensDelta { rec.thinkingDeltaFromSystem.append(d) }
    case .result(let r):
        if case .success(let s) = r {
            resultBox.totalInput = s.usage?.inputTokens
            resultBox.totalOutput = s.usage?.outputTokens
            resultBox.totalCacheCreation = s.usage?.cacheCreationInputTokens
            resultBox.totalCacheRead = s.usage?.cacheReadInputTokens
            resultBox.costUsd = s.totalCostUsd
            resultBox.numTurns = s.numTurns
            resultBox.durationMs = s.durationMs
            if let mu = s.modelUsage {
                var lines: [String] = []
                for (name, v) in mu.sorted(by: { $0.key < $1.key }) {
                    lines.append(
                        "    \(name): in=\(v.inputTokens ?? 0) out=\(v.outputTokens ?? 0) "
                            + "cacheCreate=\(v.cacheCreationInputTokens ?? 0) "
                            + "cacheRead=\(v.cacheReadInputTokens ?? 0) "
                            + "cost=\(v.costUsd.map { String(format: "$%.5f", $0) } ?? "n/a") "
                            + "ctxWindow=\(v.contextWindow ?? 0)")
                }
                resultBox.modelUsageDump = lines.joined(separator: "\n")
            }
        }
        if !resultFired {
            resultFired = true
            resultSeen.signal()
        }
    default:
        break
    }
}

session.onStderr = { text in
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    log("[stderr] \(trimmed)")
}
session.onProcessExit = { code in log("process exit code=\(code)") }

// MARK: - Drive the turn

do {
    try await session.start()
    log("session.start ok")
} catch {
    log("ERROR session.start: \(error)")
    exit(1)
}

let initDone = DispatchSemaphore(value: 0)
session.initialize(promptSuggestions: false) { _ in initDone.signal() }
if initDone.wait(timeout: .now() + 60) == .timedOut {
    log("ERROR initialize timeout")
    session.close()
    exit(1)
}

log("sending prompt (chars=\(prompt.count))")
session.sendMessage(prompt, extra: ["uuid": UUID().uuidString.lowercased()])

if resultSeen.wait(timeout: .now() + timeoutSec) == .timedOut {
    log("ERROR result timeout after \(timeoutSec)s")
    session.close()
    exit(1)
}
Thread.sleep(forTimeInterval: 0.6)  // drain trailing stream_event

// MARK: - Report

func line(_ s: String = "") { log(s) }
func sumAuthInput() -> Int { tally.order.compactMap { tally.byId[$0] }.reduce(0) { $0 + $1.authoritativeInput } }
func sumAuthOutput() -> Int { tally.order.compactMap { tally.byId[$0] }.reduce(0) { $0 + $1.authoritativeOutput } }

line()
line("============================================================")
line(" #249 token-usage ground truth — \(tally.order.count) assistant message(s)")
line(" model=\(model ?? "(CLI default)")  effort=\(effort?.rawValue ?? "(none)")")
line("============================================================")

for (i, id) in tally.order.enumerated() {
    guard let r = tally.byId[id] else { continue }
    line()
    line("── assistant message #\(i + 1)  id=\(id) ──")
    line(
        "  message_start.usage : input=\(r.startInput.map(String.init) ?? "—")  "
            + "output(placeholder)=\(r.startOutput.map(String.init) ?? "—")  "
            + "cacheCreate=\(r.startCacheCreation.map(String.init) ?? "—")  "
            + "cacheRead=\(r.startCacheRead.map(String.init) ?? "—")")
    let deltas = r.deltaOutputs.map(String.init).joined(separator: " → ")
    line(
        "  message_delta.output: [\(deltas)]   (count=\(r.deltaOutputs.count))"
            + (r.deltaStopReason.map { "  stop_reason=\($0)" } ?? "")
            + (r.deltaThinkingTokens.map { "  thinking_tokens=\($0)" } ?? ""))
    func series(_ a: [Int]) -> String { a.isEmpty ? "—" : a.map(String.init).joined(separator: " → ") }
    line(
        "  thinking_delta      : count=\(r.thinkingDeltaCount)  text_chars=\(r.thinkingChars) (redacted)  "
            + "signature_delta=\(r.signatureDeltaCount)")
    line("  thinking_delta.est  : [\(series(r.thinkingDeltaIncrements))]   ← PER-FRAME INCREMENT (not a total)")
    line(
        "  system.thinking_tokens.estimated_tokens (CUMULATIVE): [\(series(r.thinkingCumulativeSeries))]")
    line(
        "  system.thinking_tokens.estimated_tokens_delta (per-frame): [\(series(r.thinkingDeltaFromSystem))]"
            + "  Σdelta=\(r.thinkingDeltaFromSystem.reduce(0, +))")
    line("  text_delta          : count=\(r.textDeltaCount)  chars=\(r.textChars) (the visible answer)")
    line(
        "  final envelope.usage: input=\(r.finalInput.map(String.init) ?? "—")  "
            + "output=\(r.finalOutput.map(String.init) ?? "—")  "
            + "cacheCreate=\(r.finalCacheCreation.map(String.init) ?? "—")  "
            + "cacheRead=\(r.finalCacheRead.map(String.init) ?? "—")")
    line("  → authoritative      : input=\(r.authoritativeInput)  output=\(r.authoritativeOutput)")
}

line()
line("── TURN USAGE (no estimation — what the pill now shows) ──")
line("  sum of authoritative input  (cache excluded) = \(sumAuthInput())")
line("  sum of authoritative output (incl. thinking) = \(sumAuthOutput())")
line("  → pill label would read:  ↑\(sumAuthInput())  ↓\(sumAuthOutput())")

line()
line("── .result envelope (CLI's own grand total) ──")
line("  usage.input_tokens          = \(resultBox.totalInput.map(String.init) ?? "—")")
line("  usage.output_tokens         = \(resultBox.totalOutput.map(String.init) ?? "—")")
line("  usage.cache_creation_tokens = \(resultBox.totalCacheCreation.map(String.init) ?? "—")")
line("  usage.cache_read_tokens     = \(resultBox.totalCacheRead.map(String.init) ?? "—")")
line("  total_cost_usd              = \(resultBox.costUsd.map { String(format: "$%.5f", $0) } ?? "—")")
line("  num_turns                   = \(resultBox.numTurns.map(String.init) ?? "—")")
line("  duration_ms                 = \(resultBox.durationMs.map(String.init) ?? "—")")
if let mu = resultBox.modelUsageDump {
    line("  modelUsage:")
    line(mu)
}

line()
line("── raw wire samples (ground truth) ──")
for (i, d) in tally.rawStartUsageDumps.enumerated() { line("  message_start.usage[\(i)]: \(d)") }
for (i, d) in tally.rawDeltaUsageDumps.enumerated() { line("  message_delta.usage[\(i)]: \(d)") }
if let t = tally.firstThinkingSnippet { line("  first thinking_delta: \(t)…") }
if let t = tally.firstTextSnippet { line("  first text_delta    : \(t)…") }

line()
let exportURL = exportDir.appendingPathComponent("\(sessionId).jsonl")
line("export jsonl: \(exportURL.path)")

// Sanity flags for a human skim.
line()
line("── sanity ──")
let recs = tally.order.compactMap { tally.byId[$0] }
let anyThinking = recs.contains { $0.thinkingDeltaCount > 0 } || recs.contains { ($0.deltaThinkingTokens ?? 0) > 0 }
line("  thinking observed: \(anyThinking ? "YES" : "NO — bump SMOKE_EFFORT=max or set SMOKE_THINKING_TOKENS")")
line(
    "  thinking text streamed: \(recs.contains { $0.thinkingChars > 0 } ? "YES" : "NO (redacted — thinking_delta.thinking is empty)")"
)
let placeholders = Set(recs.compactMap { $0.startOutput })
line("  message_start.output placeholder values seen: \(placeholders.sorted())  (NOT the real total)")

session.close()
log("done")
