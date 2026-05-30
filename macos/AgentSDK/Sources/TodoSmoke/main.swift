import AgentSDK
import Foundation

// Dump-only smoke focused on the TodoWrite tool. Spawns a real `claude`
// CLI via AgentSDK.Session, asks it to plan a small task using TodoWrite
// (which forces multiple consecutive writes), captures every JSONL line
// the CLI emits, and prints the TodoWrite-shaped payloads so we can
// confirm:
//
//   - the assistant.tool_use payload shape (`tool_use.input.todos[]`)
//   - the matching user.tool_result envelope (text body + `tool_use_result.new_todos/old_todos`)
//   - whether the CLI surfaces a "clear" / dedicated update path that
//     differs from a fresh full-list write
//
// Env: CLAUDE_BINARY_PATH (override), SMOKE_MODEL (default
// claude-sonnet-4-6).
//
// Run from `macos/AgentSDK`:
//
//   swift run TodoSmoke

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
let model = env["SMOKE_MODEL"] ?? "claude-sonnet-4-6"
let prompt =
    env["SMOKE_PROMPT"]
        ?? """
        Use the TodoWrite tool to plan the following pretend task:

        1) Read a README file
        2) Update a function in main.swift
        3) Run the unit tests

        Make THREE separate TodoWrite calls in order:
        - first call: all three items as `pending`
        - second call: first item flipped to `in_progress`
        - third call: first item `completed`, second item `in_progress`

        After the third TodoWrite call, reply with exactly the two
        letters: ok. Do NOT actually open any files or run anything;
        these are just plan items.
        """

guard let claudeBin = locateClaude() else {
    log("ERROR: no claude binary found")
    exit(1)
}

let stamp = Int(Date().timeIntervalSince1970)
let workDir = URL(fileURLWithPath: "/tmp/ccterm-todo-smoke-\(stamp)", isDirectory: true)
let exportDir = workDir.appendingPathComponent("export", isDirectory: true)
try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

let sessionId = UUID().uuidString.lowercased()

log("model=\(model) sessionId=\(sessionId)")
log("workDir=\(workDir.path)")

let config = SessionConfiguration(
    workingDirectory: workDir,
    model: model,
    sessionId: sessionId,
    binaryPath: claudeBin,
    inheritsParentEnvironment: true,
    allowDangerouslySkipPermissions: true,
    messageExportDirectory: exportDir
)

let session = AgentSDK.Session(configuration: config)
session.lastKnownSessionId = sessionId

var counts: [String: Int] = [:]
let firstResult = DispatchSemaphore(value: 0)
var resultFired = false
let processExited = DispatchSemaphore(value: 0)

func dump(label: String, payload: Any) {
    let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: opts),
        let text = String(data: data, encoding: .utf8)
    {
        FileHandle.standardError.write(Data("\n--- \(label) ---\n".utf8))
        FileHandle.standardError.write(Data(text.utf8))
        FileHandle.standardError.write(Data("\n".utf8))
    }
}

session.onMessage = { msg in
    let key: String
    switch msg {
    case .assistant(let a):
        key = "assistant"
        for block in a.message?.content ?? [] {
            if case .toolUse(let tu) = block, case .TodoWrite(let tw) = tu {
                dump(label: "assistant.tool_use TodoWrite (typed)", payload: tw.toJSON())
            }
        }
    case .user(let u):
        key = "user"
        // (A) The .toolUseResult typed branch — TodoWrite emits new_todos / old_todos here.
        if case .object(let obj) = u.toolUseResult,
            case .TodoWrite(let tw, _) = obj
        {
            dump(label: "user.tool_use_result TodoWrite (typed)", payload: tw.toJSON())
        }
        // (B) Top-level `todos` field on the user envelope. The generated
        // struct already exposes `todos: [Any]?` — check whether the CLI
        // populates it on TodoWrite responses (it may be a snapshot of
        // the live list, distinct from the embedded new_todos).
        if let topLevel = u.todos {
            dump(
                label: "user.todos (top-level)",
                payload: ["count": topLevel.count, "items": topLevel] as [String: Any]
            )
        }
    case .result:
        key = "result"
        if !resultFired {
            resultFired = true
            firstResult.signal()
        }
    case .system(.`init`): key = "system.init"
    case .system: key = "system.other"
    case .progress: key = "progress"
    case .unknown(let n, _): key = "unknown(\(n))"
    default: key = "other"
    }
    counts[key, default: 0] += 1
}
session.onStderr = { text in
    log("[stderr] \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
}
session.onProcessExit = { code in
    log("[exit] code=\(code)")
    processExited.signal()
}

do {
    try await session.start()
    log("session.start ok")
} catch {
    log("ERROR session.start: \(error)")
    exit(1)
}

let initDone = DispatchSemaphore(value: 0)
session.initialize(promptSuggestions: false) { resp in
    log("init reply: models=\(resp?.models?.count ?? 0)")
    initDone.signal()
}
if initDone.wait(timeout: .now() + 30) == .timedOut {
    log("ERROR initialize timeout")
    session.close()
    exit(1)
}

log("sending prompt…")
session.sendMessage(prompt, extra: ["uuid": UUID().uuidString.lowercased()])

if firstResult.wait(timeout: .now() + 300) == .timedOut {
    log("ERROR first .result timeout")
    session.close()
    exit(1)
}
log("first .result received — counts: \(counts.sorted { $0.key < $1.key })")

log("closing session")
session.close()
if processExited.wait(timeout: .now() + 10) == .timedOut {
    log("WARN process did not exit within 10s of close")
}

// Dump JSONL — full transcript for reference.
if let files = try? FileManager.default.contentsOfDirectory(at: exportDir, includingPropertiesForKeys: nil) {
    for url in files {
        log("--- export: \(url.lastPathComponent) ---")
        if let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
        {
            FileHandle.standardError.write(Data(text.utf8))
            FileHandle.standardError.write(Data("\n".utf8))
        }
    }
}
log("done")
