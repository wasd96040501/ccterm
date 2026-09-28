// PartialMessagesSmoke — checks `includePartialMessages` streaming against
// the real CLI.
//
// With the flag on (default), checks that:
//   - every `stream_event` line the CLI wrote reaches the consumer as a
//     `.message(.streamEvent)`, with typed sub-type counts equal to the raw
//     export's (message_start / content_block_start / content_block_delta /
//     content_block_stop / message_delta / message_stop all present);
//   - no event or delta decodes as `.unknown`;
//   - the text deltas of each block, concatenated, equal the text of the
//     finished `AssistantMessage` for that block (matched by `messageID`).
// With SMOKE_PARTIAL=0, checks that no stream events arrive at all. Both
// modes check that finished assistant text arrives and the turn succeeds.
//
//   swift run PartialMessagesSmoke
//   SMOKE_PARTIAL=0 swift run PartialMessagesSmoke
//
// Env: CLAUDE_BINARY_PATH, SMOKE_MODEL (default claude-haiku-4-5),
// SMOKE_PROMPT (default: a multi-paragraph reply), SMOKE_PARTIAL.
// Work dir (kept): /tmp/ccterm-partial-<timestamp>/.

import AgentSDK
import Foundation

let env = ProcessInfo.processInfo.environment
let model = env["SMOKE_MODEL"] ?? "claude-haiku-4-5"
let prompt =
    env["SMOKE_PROMPT"]
    ?? "Write three short paragraphs about why the sky appears blue. Be descriptive but concise. No preamble."
let partial = env["SMOKE_PARTIAL"] != "0"

let workDir = URL(fileURLWithPath: "/tmp/ccterm-partial-\(Int(Date().timeIntervalSince1970))")
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

func name(_ event: StreamEvent.Event) -> String {
    switch event {
    case .messageStart: return "message_start"
    case .contentBlockStart: return "content_block_start"
    case .contentBlockDelta: return "content_block_delta"
    case .contentBlockStop: return "content_block_stop"
    case .messageDelta: return "message_delta"
    case .messageStop: return "message_stop"
    case .ping: return "ping"
    case .unknown(let raw): return "unknown(\(raw["type"]?.stringValue ?? "?"))"
    }
}

let sessionID = UUID().uuidString.lowercased()
let session = Session(
    configuration: SessionConfiguration(
        workingDirectory: workDir, model: model, sessionId: sessionID, binaryPath: env["CLAUDE_BINARY_PATH"],
        includePartialMessages: partial, inheritsParentEnvironment: true, messageExportDirectory: exportDir))

var typedCounts: [String: Int] = [:]
var unknownDeltas = 0
var currentMessageID = ""
/// Streamed text per API response, keyed by block index.
var streamedText: [String: [Int: String]] = [:]
/// Finished text blocks per API response, in arrival order.
var finishedText: [String: [String]] = [:]
var result: ResultMessage?

func record(_ event: SessionEvent) {
    switch event {
    case .message(.streamEvent(let e)):
        typedCounts[name(e.event), default: 0] += 1
        switch e.event {
        case .messageStart(let id, _, _):
            currentMessageID = id
        case .contentBlockDelta(let index, .text(let text)):
            streamedText[currentMessageID, default: [:]][index, default: ""] += text
        case .contentBlockDelta(_, .unknown(let raw)):
            unknownDeltas += 1
            log("unknown delta: \(raw)")
        default:
            break
        }
    case .message(.assistant(let m)):
        for text in m.content.compactMap(\.text) { finishedText[m.messageID, default: []].append(text) }
    case .message(.result(let r)):
        result = r
    case .permissionRequest(let request):
        request.respond(.deny(message: "PartialMessagesSmoke runs no tools"))
    default:
        break
    }
}

_ = Task {
    try await Task.sleep(for: .seconds(180))
    log("FAIL  timed out after 180 s; work dir \(workDir.path)")
    exit(1)
}

log("model=\(model) includePartialMessages=\(partial) workDir=\(workDir.path)")
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

// Count what the CLI actually wrote, straight from the export.
var rawCounts: [String: Int] = [:]
let exportFile = exportDir.appendingPathComponent("\(sessionID).jsonl")
let exported = (try? Data(contentsOf: exportFile)) ?? Data()
for line in exported.split(separator: UInt8(ascii: "\n")) {
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
        value["type"] == "stream_event"
    else { continue }
    rawCounts[value["event"]?["type"]?.stringValue ?? "?", default: 0] += 1
}

log("raw stream_event sub-types:   \(rawCounts.sorted { $0.key < $1.key })")
log("typed stream_event sub-types: \(typedCounts.sorted { $0.key < $1.key })")
check(result?.subtype == .success, "turn succeeds (\(result?.subtype.rawValue ?? "no result"))")
check(!finishedText.isEmpty, "finished assistant text arrives")
if partial {
    let required = [
        "message_start", "content_block_start", "content_block_delta", "content_block_stop", "message_delta",
        "message_stop",
    ]
    check(required.allSatisfy { typedCounts[$0] != nil }, "all six stream sub-types arrive")
    check(typedCounts == rawCounts, "typed stream events match the raw export one for one")
    check(!typedCounts.keys.contains { $0.hasPrefix("unknown") } && unknownDeltas == 0, "no event decodes as unknown")
    var mismatches: [String] = []
    for (messageID, texts) in finishedText {
        let streamed = (streamedText[messageID] ?? [:]).sorted { $0.key < $1.key }.map(\.value)
        if streamed != texts { mismatches.append(messageID) }
    }
    check(mismatches.isEmpty, "concatenated text deltas equal each finished text block (mismatched: \(mismatches))")
} else {
    check(typedCounts.isEmpty && rawCounts.isEmpty, "no stream events without the flag (\(typedCounts.count))")
}
for (messageID, texts) in finishedText {
    log("finished \(messageID): \(texts.map { $0.prefix(60) })")
}

log(
    failures.isEmpty
        ? "PartialMessagesSmoke PASS"
        : "PartialMessagesSmoke FAIL (\(failures.count)): \(failures.joined(separator: "; "))")
log("export: \(exportFile.path)")
exit(failures.isEmpty ? 0 : 1)
