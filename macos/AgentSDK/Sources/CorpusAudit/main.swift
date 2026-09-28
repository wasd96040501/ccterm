// CorpusAudit — decodes real protocol data with the AgentSDK model and
// reports what did not map onto a typed case.
//
// Stream corpus: every `*.jsonl` under `AUDIT_EXPORT_DIR` (default
// `~/.cache/ccterm/export`), decoded line by line with `Message(jsonLine:)`.
// Disk corpus: every main transcript under `AUDIT_PROJECTS_DIR` (default
// `~/.claude/projects`), rebuilt with `Transcript(contentsOf:)`.
//
// Prints counts per message kind, every `.unknown` / `.other` kind, content
// blocks that fell back to `.unknown`, and known kinds that degraded to
// `.unknown` (a decode failure). Reads local data only; writes nothing.
//
//   swift run -c release CorpusAudit
//   AUDIT_LIMIT=50 swift run CorpusAudit       # first 50 files per corpus
//   AUDIT_UUIDS_OUT=/tmp/x.json ...            # also dump each transcript's
//                                              # non-synthetic message uuids

import AgentSDK
import Foundation

let env = ProcessInfo.processInfo.environment
let home = FileManager.default.homeDirectoryForCurrentUser
let exportDir = URL(
    fileURLWithPath: env["AUDIT_EXPORT_DIR"] ?? home.appendingPathComponent(".cache/ccterm/export").path)
let projectsDir = URL(
    fileURLWithPath: env["AUDIT_PROJECTS_DIR"] ?? home.appendingPathComponent(".claude/projects").path)
let limit = env["AUDIT_LIMIT"].flatMap(Int.init) ?? .max

var counts: [String: Int] = [:]
var degraded: [String: (count: Int, sample: String)] = [:]

func bump(_ key: String) { counts[key, default: 0] += 1 }

func note(_ key: String, _ sample: Data) {
    let text = String(decoding: sample.prefix(300), as: UTF8.self)
    degraded[key, default: (0, text)].count += 1
}

func audit(blocks: [ContentBlock], line: Data) {
    for block in blocks {
        switch block {
        case .unknown(let type, _): bump("block.unknown.\(type)")
        case .toolResult(let result): audit(blocks: result.content, line: line)
        default: break
        }
    }
}

func jsonlFiles(under root: URL, skipping skip: (URL) -> Bool = { _ in false }) -> [URL] {
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    var files: [URL] = []
    for case let url as URL in walker where url.pathExtension == "jsonl" && !skip(url) {
        files.append(url)
    }
    return files.sorted { $0.path < $1.path }
}

// MARK: - Stream corpus

let streamStart = Date()
var streamLines = 0
for file in jsonlFiles(under: exportDir).prefix(limit) {
    guard let data = try? Data(contentsOf: file) else { continue }
    for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
        streamLines += 1
        let lineData = Data(line)
        guard let message = Message(jsonLine: lineData) else {
            bump("stream.notJSON")
            continue
        }
        switch message {
        case .assistant(let m):
            bump("stream.assistant")
            audit(blocks: m.content, line: lineData)
        case .user(let m):
            bump("stream.user")
            audit(blocks: m.content, line: lineData)
        case .result: bump("stream.result")
        case .system(let s):
            if case .other(let subtype, _) = s { bump("stream.system.other.\(subtype)") } else { bump("stream.system") }
        case .streamEvent(let e):
            switch e.event {
            case .unknown(let raw): bump("stream.streamEvent.unknown.\(raw["type"]?.stringValue ?? "?")")
            case .contentBlockDelta(_, .unknown(let raw)):
                bump("stream.streamEvent.delta.unknown.\(raw["type"]?.stringValue ?? "?")")
            default: bump("stream.streamEvent")
            }
        case .toolProgress: bump("stream.toolProgress")
        case .rateLimit: bump("stream.rateLimit")
        case .commandLifecycle: bump("stream.commandLifecycle")
        case .promptSuggestion: bump("stream.promptSuggestion")
        case .unknown(let raw):
            let type = raw["type"]?.stringValue ?? "?"
            let known = [
                "assistant", "user", "result", "system", "stream_event", "tool_progress", "rate_limit_event",
                "command_lifecycle", "prompt_suggestion",
            ]
            if known.contains(type) {
                note("stream.DEGRADED.\(type)", lineData)
            } else {
                bump("stream.unknown.\(type)")
            }
        }
    }
}
let streamSeconds = Date().timeIntervalSince(streamStart)

// MARK: - Disk corpus

let diskStart = Date()
var transcripts = 0
var transcriptMessages = 0
var uuidDump: [String: [String]] = [:]
let mainFiles = jsonlFiles(under: projectsDir) {
    $0.path.contains("/subagents/") || $0.lastPathComponent.hasPrefix("agent-")
}
for file in mainFiles.prefix(limit) {
    guard let transcript = try? Transcript(contentsOf: file) else {
        bump("disk.unreadable")
        continue
    }
    transcripts += 1
    transcriptMessages += transcript.messages.count
    if env["AUDIT_UUIDS_OUT"] != nil {
        uuidDump[file.path] = transcript.messages.compactMap { message in
            switch message {
            case .assistant(let m): return m.uuid
            case .user(let m) where !m.isSynthetic: return m.uuid
            default: return nil
            }
        }
    }
    for message in transcript.messages {
        switch message {
        case .assistant(let m): audit(blocks: m.content, line: Data())
        case .user(let m): audit(blocks: m.content, line: Data())
        default: break
        }
    }
    if transcript.messages.isEmpty { bump("disk.emptyTranscript") }
}
let diskSeconds = Date().timeIntervalSince(diskStart)
if let out = env["AUDIT_UUIDS_OUT"], let data = try? JSONSerialization.data(withJSONObject: uuidDump) {
    try? data.write(to: URL(fileURLWithPath: out))
}

// MARK: - Report

print("stream: \(streamLines) lines in \(String(format: "%.1f", streamSeconds)) s")
print("disk:   \(transcripts) transcripts, \(transcriptMessages) messages in \(String(format: "%.1f", diskSeconds)) s")
print("")
for (key, count) in counts.sorted(by: { $0.key < $1.key }) {
    print(String(format: "%9d  %@", count, key))
}
if degraded.isEmpty {
    print("\nno known kind degraded to .unknown")
} else {
    print("\nDEGRADED (known kind failed to decode):")
    for (key, value) in degraded.sorted(by: { $0.key < $1.key }) {
        print("  \(key): \(value.count)\n    \(value.sample)")
    }
}
