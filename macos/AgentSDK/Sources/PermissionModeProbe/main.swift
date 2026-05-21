import AgentSDK
import Foundation

// Real-CLI probe for "where does the CLI surface a permission_mode change
// after the client responds to a permission_request with allowAlways +
// permission_suggestions[type=setMode]?".
//
// Boots a fresh session with permissionMode=.default and the dangerous-skip
// flag OFF, issues a prompt that should trigger a specific tool, captures
// the resulting permission_request and its permission_suggestions verbatim,
// responds with allowAlways (echoing those suggestions back to the CLI),
// then dumps every subsequent JSONL line to stderr so we can see exactly
// which message types ever carry `permission_mode`.
//
// Run from `macos/AgentSDK`:
//
//   swift run PermissionModeProbe                       # default: edit
//   SMOKE_SCENARIO=bash       swift run PermissionModeProbe
//   SMOKE_SCENARIO=write      swift run PermissionModeProbe
//   SMOKE_SCENARIO=webfetch   swift run PermissionModeProbe
//   SMOKE_SCENARIO=enterplan  swift run PermissionModeProbe
//   SMOKE_SCENARIO=exitplan   swift run PermissionModeProbe
//
// Env: CLAUDE_BINARY_PATH (override), SMOKE_MODEL (default claude-haiku-4-5),
//      SMOKE_DRAIN_SECONDS (default 8).

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(ts)] \(msg)\n".utf8))
}

func dumpJSON(_ tag: String, _ obj: Any) {
    let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    let str = String(data: data, encoding: .utf8) ?? "<unprintable>"
    log("\(tag) \(str)")
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

enum Scenario: String { case bash, edit, write, webfetch, enterplan, exitplan }

let env = ProcessInfo.processInfo.environment
let scenario = Scenario(rawValue: env["SMOKE_SCENARIO"] ?? "edit") ?? .edit
let model = env["SMOKE_MODEL"] ?? "claude-haiku-4-5"
let drainSeconds = TimeInterval(Int(env["SMOKE_DRAIN_SECONDS"] ?? "8") ?? 8)

guard let claudeBin = locateClaude() else {
    log("ERROR: no claude binary found")
    exit(1)
}

let stamp = Int(Date().timeIntervalSince1970)
let workDir = URL(
    fileURLWithPath: "/tmp/ccterm-permission-probe-\(scenario.rawValue)-\(stamp)",
    isDirectory: true)
let exportDir = workDir.appendingPathComponent("export", isDirectory: true)
try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

// Scenario-specific filesystem setup + prompt.
let targetFile = workDir.appendingPathComponent("target.txt")
let prompt: String
switch scenario {
case .bash:
    prompt = "Use the Bash tool to run exactly `echo probe-ok` and then reply with 'done'."
case .edit:
    try "hello\n".write(to: targetFile, atomically: true, encoding: .utf8)
    prompt =
        "Use the Edit tool to change the word 'hello' to 'world' inside "
        + "\(targetFile.path). After that reply with 'done'."
case .write:
    prompt =
        "Use the Write tool to create the file \(workDir.path)/new.txt with the "
        + "single line `created`. Then reply with 'done'."
case .webfetch:
    prompt =
        "Use the WebFetch tool to fetch https://example.com and summarize "
        + "the page title in one short sentence."
case .enterplan:
    prompt =
        "Before doing anything else, call the EnterPlanMode tool to plan a "
        + "trivial refactor of a hypothetical hello-world script. We are "
        + "currently in default permission mode."
case .exitplan:
    // The CLI only exposes ExitPlanMode after EnterPlanMode succeeded, so
    // ask it to enter then exit. We respond allowAlways to BOTH requests so
    // the second one (ExitPlanMode) is the one that carries setMode→default
    // in its permission_suggestions.
    prompt =
        "Step 1: call EnterPlanMode and produce a one-line plan that says "
        + "'no-op'. Step 2: call ExitPlanMode with that plan so we leave "
        + "plan mode. After the tool returns, reply with 'done'."
}

let sessionId = UUID().uuidString.lowercased()
log("scenario=\(scenario.rawValue) model=\(model) sessionId=\(sessionId)")
log("workDir=\(workDir.path)")

// settingSources=[] suppresses user/project/local settings so the CLI
// doesn't auto-allow Edit/Bash via the developer's own ~/.claude/settings.json
// rules — without this the prompt would never become a permission_request.
let config = SessionConfiguration(
    workingDirectory: workDir,
    model: model,
    permissionMode: .default,
    sessionId: sessionId,
    binaryPath: claudeBin,
    settingSources: [],
    inheritsParentEnvironment: true,
    allowDangerouslySkipPermissions: false,
    messageExportDirectory: exportDir)

let session = AgentSDK.Session(configuration: config)
session.lastKnownSessionId = sessionId

// Track which messages carry a permission_mode field.
struct ModeSighting {
    let kind: String
    let mode: String
}
var sightings: [ModeSighting] = []
let firstResult = DispatchSemaphore(value: 0)
var resultFired = false
let processExited = DispatchSemaphore(value: 0)
var permissionRequestSeq = 0

func noteIfModeBearing(kind: String, raw: [String: Any]) {
    // CLI uses both snake_case (`permission_mode`, e.g. in user.replay rows)
    // and camelCase (`permissionMode`, e.g. in system.init / system.status)
    // for the same field — match both so we don't undercount.
    if let mode = (raw["permission_mode"] ?? raw["permissionMode"]) as? String {
        sightings.append(ModeSighting(kind: kind, mode: mode))
        log("MODE-FIELD-FOUND kind=\(kind) mode=\(mode)")
    }
}

session.onMessage = { msg in
    switch msg {
    case .assistant(let a):
        noteIfModeBearing(kind: "assistant", raw: a._raw)
    case .user(let u):
        // u._raw is [String: Any]
        noteIfModeBearing(kind: "user", raw: u._raw)
        dumpJSON("USER-RAW", u._raw)
    case .result(let r):
        let raw: [String: Any]
        switch r {
        case .success(let s): raw = s._raw
        case .errorDuringExecution(let e): raw = e._raw
        case .unknown(_, let dict): raw = dict
        }
        noteIfModeBearing(kind: "result", raw: raw)
        log("RESULT received")
        if !resultFired {
            resultFired = true
            firstResult.signal()
        }
    case .system(.`init`(let info)):
        noteIfModeBearing(kind: "system.init", raw: info._raw)
        dumpJSON("SYSTEM-INIT", info._raw)
    case .system(.status(let s)):
        noteIfModeBearing(kind: "system.status", raw: s._raw)
        dumpJSON("SYSTEM-STATUS", s._raw)
    case .system(let other):
        // Dump anything else under system so we don't miss an unexpected carrier.
        log("SYSTEM-OTHER variant=\(other)")
    case .progress:
        break
    case .unknown(let name, let raw):
        log("UNKNOWN-MSG name=\(name)")
        dumpJSON("UNKNOWN-RAW", raw)
    default:
        break
    }
}

session.onStderr = { text in
    log("[stderr] \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
}
session.onProcessExit = { code in
    log("[exit] code=\(code)")
    processExited.signal()
}

// For ExitPlanMode we want to test how the CLI reacts to each of the
// distinct mode targets the upstream UI offers (default / acceptEdits /
// bypassPermissions / plan-keep). SMOKE_EXIT_MODE selects which one we
// inject via updatedPermissions; null falls back to the CLI's own
// suggestions (which are empty for ExitPlanMode).
let exitModeOverride = env["SMOKE_EXIT_MODE"]  // "default" | "acceptEdits" | "bypassPermissions" | "plan" | nil

session.onPermissionRequest = { request, completion in
    permissionRequestSeq += 1
    let seq = permissionRequestSeq
    log("PERMISSION-REQ #\(seq) tool=\(request.toolName) requestId=\(request.requestId)")
    dumpJSON("PERMISSION-REQ-RAW", request._raw)
    let suggestions: [[String: Any]] =
        (request.permissionSuggestions?.compactMap { $0.toJSON() as? [String: Any] }) ?? []
    log("PERMISSION-REQ #\(seq) suggestion-count=\(suggestions.count)")
    for (i, s) in suggestions.enumerated() {
        dumpJSON("PERMISSION-REQ #\(seq) suggestion[\(i)]", s)
    }

    // ExitPlanMode override: inject a synthetic setMode update so we can
    // observe what the CLI actually broadcasts for each branch.
    if request.toolName == "ExitPlanMode", let mode = exitModeOverride {
        let update: [String: Any] = [
            "type": "setMode",
            "mode": mode,
            "destination": "session",
        ]
        log("PERMISSION-REQ #\(seq) overriding updatedPermissions with mode=\(mode)")
        completion(request.allowAlways(updatedPermissions: [update]))
        return
    }
    log("PERMISSION-REQ #\(seq) responding allowAlways (echoing suggestions)")
    completion(request.allowAlways())
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

log("sending prompt: \(prompt)")
session.sendMessage(prompt, extra: ["uuid": UUID().uuidString.lowercased()])

if firstResult.wait(timeout: .now() + 180) == .timedOut {
    log("ERROR first .result timeout")
    session.close()
    exit(1)
}

if drainSeconds > 0 {
    log("post-result drain window \(Int(drainSeconds))s — watching for late system.status / etc")
    Thread.sleep(forTimeInterval: drainSeconds)
}

log("closing session")
session.close()
if processExited.wait(timeout: .now() + 10) == .timedOut {
    log("WARN process did not exit within 10s of close")
}

// Summarise.
log("=============== SUMMARY ===============")
log("permission requests handled: \(permissionRequestSeq)")
log("messages carrying permission_mode: \(sightings.count)")
for s in sightings {
    log("  - kind=\(s.kind) mode=\(s.mode)")
}

// Dump JSONL for offline grep.
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
