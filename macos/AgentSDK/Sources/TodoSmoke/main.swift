// TodoSmoke — checks the typed task-list tool I/O (`Tools.TaskCreate`,
// `Tools.TaskUpdate`) against what the real CLI records.
//
// Asks the model to create three pretend tasks with TaskCreate and move them
// along with TaskUpdate, then matches every tool result to its call by
// `toolUseID`. Checks:
//   - each TaskCreate input decodes with `input(as:)` and its outcome is
//     `.success` with a task id and the same subject;
//   - each TaskUpdate input decodes with a known task id and a status, and
//     its outcome is `.success` with `success == true` for that id;
//   - the updates cover `in_progress` and `completed`, and the turn succeeds.
// Prints every decoded input and raw `toolUseResult`. A TodoWrite call (older
// CLIs) is decoded and printed but not required.
//
//   swift run TodoSmoke
//
// Env: CLAUDE_BINARY_PATH, SMOKE_MODEL (default claude-haiku-4-5), SMOKE_PROMPT.
// Work dir (kept): /tmp/ccterm-todo-<timestamp>/.

import AgentSDK
import Foundation

let env = ProcessInfo.processInfo.environment
let model = env["SMOKE_MODEL"] ?? "claude-haiku-4-5"
let prompt =
    env["SMOKE_PROMPT"]
        ?? """
        Plan this pretend task with your task-list tools. Do NOT open any files or run anything.

        1. Use TaskCreate three times, one call per item: "Read the README", "Update a function in main.swift", \
        "Run the unit tests".
        2. Use TaskUpdate to set the first task to in_progress.
        3. Use TaskUpdate to set the first task to completed, then TaskUpdate to set the second to in_progress.

        Then reply with exactly the two letters: ok
        """

let workDir = URL(fileURLWithPath: "/tmp/ccterm-todo-\(Int(Date().timeIntervalSince1970))")
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

func jsonString(_ value: JSONValue?) -> String {
    guard let value, let data = try? JSONEncoder().encode(value) else { return "nil" }
    return String(decoding: data, as: UTF8.self)
}

let session = Session(
    configuration: SessionConfiguration(
        workingDirectory: workDir, model: model, sessionId: UUID().uuidString.lowercased(),
        binaryPath: env["CLAUDE_BINARY_PATH"], inheritsParentEnvironment: true, messageExportDirectory: exportDir))

var calls: [String: ToolUseBlock] = [:]
var createdIDs: [String] = []
var creates = 0
var updates = 0
var updatedStatuses: Set<Tools.TaskStatus> = []
var result: ResultMessage?

func verifyCreate(_ call: ToolUseBlock, _ message: UserMessage) {
    creates += 1
    let input = call.input(as: Tools.TaskCreate.self)
    log("TaskCreate input subject=\(input?.subject.debugDescription ?? "undecodable")")
    log("  toolUseResult=\(jsonString(message.toolUseResult))")
    let outcome = message.toolOutcome(Tools.TaskCreate.self)
    guard case .success(let output)? = outcome else {
        check(false, "TaskCreate #\(creates) outcome is success (\(String(describing: outcome)))")
        return
    }
    createdIDs.append(output.taskID)
    check(
        input != nil && !output.taskID.isEmpty && output.subject == input?.subject,
        "TaskCreate #\(creates) decodes: id=\(output.taskID) subject=\(output.subject.debugDescription)")
}

func verifyUpdate(_ call: ToolUseBlock, _ message: UserMessage) {
    updates += 1
    let input = call.input(as: Tools.TaskUpdate.self)
    log("TaskUpdate input id=\(input?.taskID ?? "undecodable") status=\(input?.status?.rawValue ?? "nil")")
    log("  toolUseResult=\(jsonString(message.toolUseResult))")
    if let status = input?.status { updatedStatuses.insert(status) }
    let outcome = message.toolOutcome(Tools.TaskUpdate.self)
    guard case .success(let output)? = outcome else {
        check(false, "TaskUpdate #\(updates) outcome is success (\(String(describing: outcome)))")
        return
    }
    check(
        input.map { createdIDs.contains($0.taskID) && $0.status != nil } == true && output.success
            && output.taskID == input?.taskID,
        "TaskUpdate #\(updates) decodes: id=\(output.taskID) success=\(output.success) "
            + "updated=\(output.updatedFields) error=\(output.error ?? "nil")")
}

func record(_ event: SessionEvent) {
    switch event {
    case .message(.assistant(let m)):
        for case .toolUse(let use) in m.content {
            calls[use.id] = use
            if let todo = use.input(as: Tools.TodoWrite.self) {
                log("TodoWrite input \(todo.todos.map { "\($0.content) [\($0.status.rawValue)]" })")
            }
        }
    case .message(.user(let m)):
        guard let id = m.toolResult?.toolUseID, let call = calls[id] else { return }
        if Tools.TaskCreate.matches(call.name) {
            verifyCreate(call, m)
        } else if Tools.TaskUpdate.matches(call.name) {
            verifyUpdate(call, m)
        } else {
            log("\(call.name) result \(jsonString(m.toolUseResult).prefix(200))")
        }
    case .message(.result(let r)):
        result = r
    case .permissionRequest(let request):
        log("permission request tool=\(request.toolName) → allow")
        request.respond(.allow())
    default:
        break
    }
}

_ = Task {
    try await Task.sleep(for: .seconds(300))
    log("FAIL  timed out after 300 s; work dir \(workDir.path)")
    exit(1)
}

log("model=\(model) workDir=\(workDir.path)")
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

check(creates >= 3, "three TaskCreate calls (\(creates))")
check(updates >= 2, "at least two TaskUpdate calls (\(updates))")
check(
    updatedStatuses.isSuperset(of: [.inProgress, .completed]),
    "updates cover in_progress and completed (\(updatedStatuses.map(\.rawValue).sorted()))")
check(result?.subtype == .success, "turn succeeds (\(result?.subtype.rawValue ?? "no result"))")

log(failures.isEmpty ? "TodoSmoke PASS" : "TodoSmoke FAIL (\(failures.count)): \(failures.joined(separator: "; "))")
log("work dir: \(workDir.path)")
exit(failures.isEmpty ? 0 : 1)
