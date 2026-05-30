import AgentSDK
import Foundation

// Smoke for `--include-partial-messages` + the `onStreamEvent` split.
//
// Verifies, against a real `claude` subprocess:
//
//   1. With the flag ON, the CLI emits `stream_event` envelopes and
//      the SDK delivers each one to `Session.onStreamEvent` as a typed
//      `Message2StreamEvent` (NOT to `onMessage`).
//   2. The typed `event` discriminator surfaces all 6 SSE sub-types
//      (message_start / content_block_start / content_block_delta /
//      content_block_stop / message_delta / message_stop).
//   3. Each typed envelope round-trips: `event._raw` matches what CLI
//      put on the wire, so callers can dig into untyped fields.
//   4. With the flag OFF, `onStreamEvent` is never called, and
//      `onMessage` still works as before (regression net for the
//      callback split).
//
// Run from `macos/AgentSDK`:
//
//   swift run PartialMessagesSmoke               # flag ON (default)
//   SMOKE_PARTIAL=0 swift run PartialMessagesSmoke   # flag OFF baseline
//
// Env:
//   CLAUDE_BINARY_PATH — override claude binary lookup
//   SMOKE_MODEL        — default claude-haiku-4-5
//   SMOKE_PROMPT       — default produces a multi-paragraph reply

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
let model = env["SMOKE_MODEL"] ?? "claude-haiku-4-5"
let prompt =
    env["SMOKE_PROMPT"]
    ?? ("Write three short paragraphs about why the sky appears blue. "
        + "Be descriptive but concise. No preamble.")
let partialOn = (env["SMOKE_PARTIAL"] ?? "1") != "0"

guard let claudeBin = locateClaude() else {
    log("ERROR: no claude binary found")
    exit(1)
}

let stamp = Int(Date().timeIntervalSince1970)
let workDir = URL(
    fileURLWithPath: "/tmp/ccterm-partial-smoke-\(stamp)", isDirectory: true)
let exportDir = workDir.appendingPathComponent("export", isDirectory: true)
try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

let sessionId = UUID().uuidString.lowercased()
log("workDir=\(workDir.path)")
log("sessionId=\(sessionId) model=\(model) includePartialMessages=\(partialOn)")

let config = SessionConfiguration(
    workingDirectory: workDir,
    model: model,
    sessionId: sessionId,
    binaryPath: claudeBin,
    includePartialMessages: partialOn,
    inheritsParentEnvironment: true,
    allowDangerouslySkipPermissions: true,
    messageExportDirectory: exportDir
)

let session = AgentSDK.Session(configuration: config)
session.lastKnownSessionId = sessionId

final class Tally: @unchecked Sendable {
    // onMessage path
    var onMessageCountByLabel: [String: Int] = [:]
    var onMessageSawStreamEvent = false  // regression: must stay false

    // onStreamEvent path
    var onStreamEventCount = 0
    var streamEventSubtypeCounts: [String: Int] = [:]
    var streamEventBodyDispatched: [String: Int] = [:]  // by enum case name
    var streamEventRawRoundtripFailures = 0
    var firstStreamEventRaws: [String] = []

    // Cross-channel detail
    var assistantTextSnapshots: [String] = []
    var partialTextChars = 0
    var partialThinkingChars = 0
}
let tally = Tally()

let resultSeen = DispatchSemaphore(value: 0)
var resultFired = false

session.onMessage = { (msg: Message2) in
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
    case .streamEvent:
        // INVARIANT: stream_event must NOT arrive on onMessage.
        // If it does, the split is broken.
        tally.onMessageSawStreamEvent = true
        label = "streamEvent(LEAKED)"
    case .user: label = "user"
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
        case .thinkingTokens: label = "system.thinkingTokens"
        case .turnDuration: label = "system.turnDuration"
        case .unknown(let n, _): label = "system.unknown(\(n))"
        }
    }
    tally.onMessageCountByLabel[label, default: 0] += 1

    switch msg {
    case .assistant(let a):
        let blocks = a.message?.content ?? []
        var parts: [String] = []
        for block in blocks {
            if case .text(let t) = block, let txt = t.text, !txt.isEmpty {
                parts.append(String(txt.prefix(60)))
            }
        }
        if !parts.isEmpty {
            tally.assistantTextSnapshots.append(parts.joined(separator: " | "))
        }
    case .result:
        if !resultFired {
            resultFired = true
            resultSeen.signal()
        }
    default:
        break
    }
}

session.onStreamEvent = { (evt: Message2StreamEvent) in
    tally.onStreamEventCount += 1

    let sub: String
    let dispatch: String
    switch evt.event {
    case .messageStart:
        sub = "message_start"
        dispatch = "messageStart"
    case .contentBlockStart(let b):
        sub = "content_block_start"
        dispatch = "contentBlockStart(idx=\(b.index ?? -1))"
    case .contentBlockDelta(let b):
        sub = "content_block_delta"
        dispatch = "contentBlockDelta(idx=\(b.index ?? -1))"
        // Pull partial text chars per delta type for sanity-check
        if let d = b.delta {
            switch d["type"] as? String {
            case "text_delta":
                tally.partialTextChars += (d["text"] as? String)?.count ?? 0
            case "thinking_delta":
                tally.partialThinkingChars += (d["thinking"] as? String)?.count ?? 0
            default:
                break
            }
        }
    case .contentBlockStop(let b):
        sub = "content_block_stop"
        dispatch = "contentBlockStop(idx=\(b.index ?? -1))"
    case .messageDelta:
        sub = "message_delta"
        dispatch = "messageDelta"
    case .messageStop:
        sub = "message_stop"
        dispatch = "messageStop"
    case .unknown(let name, _):
        sub = name
        dispatch = "unknown(\(name))"
    case .none:
        sub = "(nil)"
        dispatch = "nil"
    }
    tally.streamEventSubtypeCounts[sub, default: 0] += 1
    tally.streamEventBodyDispatched[dispatch, default: 0] += 1

    // Round-trip check: re-serialize _raw and confirm the event-type
    // discriminator survives. (Full deep-equality is brittle because
    // JSONSerialization may reorder keys; the discriminator is
    // sufficient evidence that we didn't lose the envelope contents.)
    if let raw = evt._raw["event"] as? [String: Any],
        let rawType = raw["type"] as? String
    {
        if rawType != sub && sub != "(nil)" {
            tally.streamEventRawRoundtripFailures += 1
        }
    } else if evt._raw["event"] != nil {
        tally.streamEventRawRoundtripFailures += 1
    }

    // Capture first 3 typed envelopes as JSON for human inspection.
    if tally.firstStreamEventRaws.count < 3 {
        if let data = try? JSONSerialization.data(
            withJSONObject: evt.toTypedJSON(), options: [.prettyPrinted, .sortedKeys]),
            let s = String(data: data, encoding: .utf8)
        {
            tally.firstStreamEventRaws.append(s)
        }
    }
}

session.onStderr = { text in
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    log("[stderr] \(trimmed)")
}
session.onProcessExit = { code in
    log("process exit code=\(code)")
}

do {
    try await session.start()
    log("session.start ok")
} catch {
    log("ERROR session.start: \(error)")
    exit(1)
}

let initDone = DispatchSemaphore(value: 0)
session.initialize(promptSuggestions: false) { _ in initDone.signal() }
if initDone.wait(timeout: .now() + 30) == .timedOut {
    log("ERROR initialize timeout")
    session.close()
    exit(1)
}

log("sending prompt (chars=\(prompt.count))")
let userUUID = UUID().uuidString.lowercased()
session.sendMessage(prompt, extra: ["uuid": userUUID])

if resultSeen.wait(timeout: .now() + 120) == .timedOut {
    log("ERROR result timeout")
    session.close()
    exit(1)
}
// Brief drain so a trailing stream_event doesn't get cut off.
Thread.sleep(forTimeInterval: 0.5)

// Cross-check against the raw stdout dump.
let exportURL = exportDir.appendingPathComponent("\(sessionId).jsonl")
var rawCountByType: [String: Int] = [:]
var rawStreamEventSubtypes: [String: Int] = [:]
var rawLineTotal = 0
if let data = try? Data(contentsOf: exportURL),
    let text = String(data: data, encoding: .utf8)
{
    for line in text.split(separator: "\n") {
        rawLineTotal += 1
        guard let d = line.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            let type = json["type"] as? String
        else { continue }
        rawCountByType[type, default: 0] += 1
        if type == "stream_event",
            let event = json["event"] as? [String: Any],
            let subtype = event["type"] as? String
        {
            rawStreamEventSubtypes[subtype, default: 0] += 1
        }
    }
}

log("")
log("============================================================")
log(" includePartialMessages = \(partialOn)")
log("============================================================")
log("")
log("== RAW STDOUT (CLI → SDK), \(rawLineTotal) lines total ==")
for (type, count) in rawCountByType.sorted(by: { $0.key < $1.key }) {
    log(String(format: "  %5d   %@", count, type))
}
if !rawStreamEventSubtypes.isEmpty {
    log("  ── stream_event subtypes:")
    for (sub, count) in rawStreamEventSubtypes.sorted(by: { $0.key < $1.key }) {
        log(String(format: "         %5d   %@", count, sub))
    }
}
log("")
log("== onMessage (SDK → caller), by label ==")
let onMessageTotal = tally.onMessageCountByLabel.values.reduce(0, +)
for (label, count) in tally.onMessageCountByLabel.sorted(by: { $0.key < $1.key }) {
    log(String(format: "  %5d   %@", count, label))
}
log("  ── total: \(onMessageTotal)")
log("")
log("== onStreamEvent (SDK → caller, partials only) ==")
log("  total invocations          : \(tally.onStreamEventCount)")
log("  by sub-type (from .event)  :")
for (sub, count) in tally.streamEventSubtypeCounts.sorted(by: { $0.key < $1.key }) {
    log(String(format: "         %5d   %@", count, sub))
}
log("  partial text chars (text_delta)    : \(tally.partialTextChars)")
log("  partial thinking chars (thinking_delta): \(tally.partialThinkingChars)")
log("  _raw round-trip failures   : \(tally.streamEventRawRoundtripFailures)")
log("")
log("== INVARIANTS ==")
let leaked = tally.onMessageSawStreamEvent
let rawStreamEvents = rawCountByType["stream_event"] ?? 0
let streamEventCountMatches = tally.onStreamEventCount == rawStreamEvents
let subtypeCountsMatch = tally.streamEventSubtypeCounts == rawStreamEventSubtypes
let roundtripClean = tally.streamEventRawRoundtripFailures == 0
let onMessageWorking = (tally.onMessageCountByLabel["assistant"] ?? 0) >= 1

var failures: [String] = []
if leaked {
    failures.append("FAIL: stream_event leaked into onMessage (split is broken)")
}
if partialOn && !streamEventCountMatches {
    failures.append(
        "FAIL: onStreamEvent count (\(tally.onStreamEventCount)) != raw stream_event count (\(rawStreamEvents))"
    )
}
if partialOn && !subtypeCountsMatch {
    failures.append(
        "FAIL: typed sub-type counts != raw sub-type counts\n     typed=\(tally.streamEventSubtypeCounts)\n     raw  =\(rawStreamEventSubtypes)"
    )
}
if partialOn && !roundtripClean {
    failures.append("FAIL: _raw round-trip discriminator mismatch")
}
if !partialOn && tally.onStreamEventCount > 0 {
    failures.append(
        "FAIL: onStreamEvent fired \(tally.onStreamEventCount) times despite flag off"
    )
}
if !onMessageWorking {
    failures.append("FAIL: no assistant message arrived via onMessage (regression)")
}

if failures.isEmpty {
    log("  PASS  ✓ all invariants hold (partial=\(partialOn))")
    log("  - onMessage leak                       : ok (no stream_event observed)")
    log(
        "  - onStreamEvent count vs raw           : ok (\(tally.onStreamEventCount) == \(rawStreamEvents))"
    )
    log(
        "  - typed sub-type tally vs raw          : ok (\(tally.streamEventSubtypeCounts.count) sub-types match)"
    )
    log("  - _raw round-trip                      : ok")
    log("  - onMessage assistant arrival          : ok")
} else {
    for f in failures { log("  \(f)") }
}
log("")
log("== First 3 typed stream_event toTypedJSON() ==")
for (i, raw) in tally.firstStreamEventRaws.enumerated() {
    log("---- typed envelope #\(i + 1) ----")
    for line in raw.split(separator: "\n") {
        log("  \(line)")
    }
}
log("")
log("== Final assistant envelopes (onMessage path) ==")
log("  assistant events: \(tally.onMessageCountByLabel["assistant"] ?? 0)")
for (i, snap) in tally.assistantTextSnapshots.enumerated() {
    log("  #\(i + 1): \(snap)")
}
log("")
log("export jsonl: \(exportURL.path)")

session.close()
log("done")

// Exit non-zero on invariant failure so CI / scripts can detect.
if !failures.isEmpty { exit(2) }
