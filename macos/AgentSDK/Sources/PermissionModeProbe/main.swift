// PermissionModeProbe — shows where the CLI reports a permission-mode change
// after a `PermissionRequest` is allowed with mode-changing
// `PermissionUpdate`s ("allow always"), against the real CLI.
//
// Starts in `.default` mode with no settings sources (so the developer's own
// allow rules cannot pre-approve the tool), sends a prompt that makes the
// model call the scenario's tool, and answers every request with
// `.allow(updatedPermissions: request.suggestions)`. For ExitPlanMode,
// SMOKE_EXIT_MODE (default / acceptEdits / bypassPermissions / plan) sends
// `.setMode(<mode>, destination: .session)` instead, since the CLI suggests
// nothing there. After the turn it keeps reading for SMOKE_DRAIN_SECONDS.
// Checks:
//   - the scenario's tool asked for permission (EnterPlanMode needs none);
//   - the turn ends `.success`;
//   - every mode sent back in a `.setMode` update (and `plan` for the plan
//     scenarios) is later reported by `SystemMessage.status` or `.initialized`.
// Prints each request's suggestions, every typed mode report, and every raw
// exported line that carries `permissionMode` / `permission_mode`.
//
//   swift run PermissionModeProbe                     # edit
//   SMOKE_SCENARIO=bash swift run PermissionModeProbe  # bash, write, webfetch, enterplan, exitplan
//   SMOKE_SCENARIO=exitplan SMOKE_EXIT_MODE=acceptEdits swift run PermissionModeProbe
//
// Env: CLAUDE_BINARY_PATH, SMOKE_MODEL (default claude-haiku-4-5), SMOKE_PROMPT
// (overrides the scenario's prompt), SMOKE_SCENARIO, SMOKE_EXIT_MODE,
// SMOKE_DRAIN_SECONDS (default 8). Work dir (kept):
// /tmp/ccterm-permission-probe-<scenario>-<timestamp>/.

import AgentSDK
import Foundation

enum Scenario: String {
    case bash, edit, write, webfetch, enterplan, exitplan
}

let env = ProcessInfo.processInfo.environment
guard let scenario = Scenario(rawValue: env["SMOKE_SCENARIO"] ?? "edit") else {
    FileHandle.standardError.write(Data("SMOKE_SCENARIO must be bash|edit|write|webfetch|enterplan|exitplan\n".utf8))
    exit(2)
}
let model = env["SMOKE_MODEL"] ?? "claude-haiku-4-5"
let exitMode = env["SMOKE_EXIT_MODE"].map { PermissionMode(rawValue: $0) }
if case .some(nil) = exitMode {
    FileHandle.standardError.write(Data("SMOKE_EXIT_MODE is not a permission mode\n".utf8))
    exit(2)
}
let drainSeconds = Int(env["SMOKE_DRAIN_SECONDS"] ?? "") ?? 8

let workDir = URL(
    fileURLWithPath: "/tmp/ccterm-permission-probe-\(scenario.rawValue)-\(Int(Date().timeIntervalSince1970))")
let exportDir = workDir.appendingPathComponent("export")
try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

let target = workDir.appendingPathComponent("target.txt")
let tool: String
let defaultPrompt: String
switch scenario {
case .bash:
    tool = "Bash"
    defaultPrompt = "Use the Bash tool to run exactly `touch probe-ok.txt` and then reply with 'done'."
case .edit:
    tool = "Edit"
    try "hello\n".write(to: target, atomically: true, encoding: .utf8)
    defaultPrompt =
        "Use the Edit tool to change the word 'hello' to 'world' inside \(target.path). After that reply with 'done'."
case .write:
    tool = "Write"
    defaultPrompt =
        "Use the Write tool to create the file \(workDir.path)/new.txt with the single line `created`. "
        + "Then reply with 'done'."
case .webfetch:
    tool = "WebFetch"
    defaultPrompt = "Use the WebFetch tool to fetch https://example.com and summarize the page title in one sentence."
case .enterplan:
    tool = "EnterPlanMode"
    defaultPrompt =
        "Before doing anything else, call the EnterPlanMode tool to plan a trivial refactor of a hypothetical "
        + "hello-world script."
case .exitplan:
    tool = "ExitPlanMode"
    defaultPrompt =
        "Step 1: call EnterPlanMode. Step 2: call ExitPlanMode with the one-line plan 'no-op' so we leave plan mode. "
        + "After the tool returns, reply with 'done'."
}
let prompt = env["SMOKE_PROMPT"] ?? defaultPrompt

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
}

var failures: [String] = []

func check(_ ok: Bool, _ what: String) {
    log("\(ok ? "PASS" : "FAIL")  \(what)")
    if !ok { failures.append(what) }
}

func jsonString(_ value: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
}

let sessionID = UUID().uuidString.lowercased()
let session = Session(
    configuration: SessionConfiguration(
        workingDirectory: workDir, model: model, permissionMode: .default, sessionId: sessionID,
        binaryPath: env["CLAUDE_BINARY_PATH"], settingSources: [], inheritsParentEnvironment: true,
        messageExportDirectory: exportDir))

var requestedTools: [String] = []
/// Modes the CLI reported, in order.
var modesReported: [(kind: String, mode: PermissionMode)] = []
/// Modes sent back in `.setMode` updates, with how many reports had arrived by then.
var modesSent: [(mode: PermissionMode, after: Int)] = []
var result: ResultMessage?

func respond(to request: PermissionRequest) {
    requestedTools.append(request.toolName)
    log("permission #\(requestedTools.count) tool=\(request.toolName) reason=\(request.decisionReason ?? "nil")")
    log("  input=\(jsonString(request.input))")
    for (i, suggestion) in request.suggestions.enumerated() { log("  suggestion[\(i)]=\(jsonString(suggestion))") }
    var updates = request.suggestions
    if request.toolName == "ExitPlanMode", let mode = exitMode ?? nil {
        updates = [.setMode(mode, destination: .session)]
    }
    for case .setMode(let mode, _) in updates { modesSent.append((mode, modesReported.count)) }
    log("  → allow, updatedPermissions=\(jsonString(updates))")
    request.respond(.allow(updatedPermissions: updates))
}

func record(_ event: SessionEvent) {
    switch event {
    case .permissionRequest(let request):
        respond(to: request)
    case .message(.system(.initialized(let i))):
        log("system.init permissionMode=\(i.permissionMode?.rawValue ?? "nil")")
        if let mode = i.permissionMode { modesReported.append(("system.init", mode)) }
    case .message(.system(.status(let s))) where s.permissionMode != nil:
        log("system.status permissionMode=\(s.permissionMode!.rawValue) status=\(s.status ?? "nil")")
        modesReported.append(("system.status", s.permissionMode!))
    case .message(.system(.permissionDenied(let d))):
        log("system.permission_denied tool=\(d.toolName) \(d.message)")
    case .message(.assistant(let m)):
        for case .toolUse(let use) in m.content { log("tool_use \(use.name) \(jsonString(use.input))") }
    case .message(.result(let r)):
        log("result \(r.subtype.rawValue) \(r.result?.prefix(60).debugDescription ?? "")")
        result = r
    default:
        break
    }
}

_ = Task {
    try await Task.sleep(for: .seconds(240))
    log("FAIL  timed out after 240 s; work dir \(workDir.path)")
    exit(1)
}

log("scenario=\(scenario.rawValue) model=\(model) workDir=\(workDir.path)")
var events = session.events.makeAsyncIterator()
do {
    try await session.start()
    try session.send(UserInput(prompt))
} catch {
    log("FAIL  start/send: \(error)")
    exit(1)
}
while result == nil, let event = await events.next() { record(event) }

log("drain window \(drainSeconds) s")
let closer = Task {
    try await Task.sleep(for: .seconds(drainSeconds))
    await session.close()
}
while let event = await events.next() { record(event) }
closer.cancel()

log("raw lines carrying a permission mode:")
let exported = (try? Data(contentsOf: exportDir.appendingPathComponent("\(sessionID).jsonl"))) ?? Data()
for line in exported.split(separator: UInt8(ascii: "\n")) {
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
        let mode = value["permissionMode"] ?? value["permission_mode"]
    else { continue }
    let kind = [value["type"]?.stringValue, value["subtype"]?.stringValue].compactMap { $0 }.joined(separator: ".")
    log("  \(kind) \(mode.stringValue ?? "?")")
}

if scenario == .enterplan {
    log("\(tool) permission requests: \(requestedTools.filter { $0 == tool }.count) (none expected)")
} else {
    check(requestedTools.contains(tool), "\(tool) asked for permission (asked: \(requestedTools))")
}
check(result?.subtype == .success, "turn ends success (\(result?.subtype.rawValue ?? "no result"))")
var expectedModes = modesSent
if scenario == .enterplan || scenario == .exitplan { expectedModes.insert((.plan, 0), at: 0) }
for (mode, after) in expectedModes {
    let reported = modesReported.dropFirst(after).contains { $0.mode == mode }
    check(reported, "the CLI reports mode \(mode.rawValue) after it is set")
}
log(
    "modes sent: \(modesSent.map(\.mode.rawValue)); reported: \(modesReported.map { "\($0.kind)=\($0.mode.rawValue)" })"
)

log(
    failures.isEmpty
        ? "PermissionModeProbe PASS"
        : "PermissionModeProbe FAIL (\(failures.count)): \(failures.joined(separator: "; "))")
log("work dir: \(workDir.path)")
exit(failures.isEmpty ? 0 : 1)
