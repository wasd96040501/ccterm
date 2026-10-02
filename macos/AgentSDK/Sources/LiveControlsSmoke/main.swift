// LiveControlsSmoke — the control requests a live session tab uses, against the
// real CLI (protocol.md *Control requests the design uses*).
//
// Checks, on a default-mode session launched WITHOUT
// `--allow-dangerously-skip-permissions`:
//   - `initialize` carries `models` (with `resolvedModel` on aliases) and the
//     current permission mode (`current_model` is only sent to a remote-control
//     attach; reported, not checked);
//   - `list_models` answers the same catalog shape;
//   - `set_permission_mode plan` succeeds and a `system/status` carries the mode;
//   - `set_permission_mode bypassPermissions` is refused with
//     `error_code: bypass_not_launched` (`AgentSDKError.refusalCode`);
//   - `set_model` with an unknown id is refused with a code, a known one is
//     acked (whether a `/model` output follows while idle is reported, not checked);
//   - `cancel_async_message` of an unknown uuid answers `{cancelled: false}`;
//     of a prompt sent while a turn runs and still `queued`, `true`, and its
//     `command_lifecycle` ends `cancelled`.
//
//   swift run LiveControlsSmoke
//
// Env: CLAUDE_BINARY_PATH, SMOKE_MODEL (default claude-haiku-4-5),
// SMOKE_TIMEOUT_SECONDS (default 90). Work dir (kept): /tmp/ccterm-live-controls-<timestamp>/.

import AgentSDK
import Foundation

let env = ProcessInfo.processInfo.environment
let model = env["SMOKE_MODEL"] ?? "claude-haiku-4-5"
let timeoutSeconds = Int(env["SMOKE_TIMEOUT_SECONDS"] ?? "") ?? 90

let workDir = URL(fileURLWithPath: "/tmp/ccterm-live-controls-\(Int(Date().timeIntervalSince1970))")
try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
}

var failures: [String] = []

func check(_ ok: Bool, _ what: String) {
    log("\(ok ? "PASS" : "FAIL")  \(what)")
    if !ok { failures.append(what) }
}

/// What the event consumer has seen.
final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [SystemMessage.Status] = []
    private var lifecycle: [String: [String]] = [:]
    private var echoes: [String] = []
    private var results = 0

    func record(_ event: SessionEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .message(.system(.status(let s))): statuses.append(s)
        case .message(.commandLifecycle(let c)): lifecycle[c.commandUUID, default: []].append(c.state.rawValue)
        case .message(.user(let u)):
            if case .commandOutput(let out, _) = u.kind { echoes.append(out) }
        case .message(.result): results += 1
        case .permissionRequest(let request): request.respond(.deny(message: "LiveControlsSmoke runs no tools"))
        default: break
        }
    }

    func states(of uuid: String) -> [String] { lock.withLock { lifecycle[uuid] ?? [] } }
    var modes: [PermissionMode] { lock.withLock { statuses.compactMap(\.permissionMode) } }
    var modelEchoes: [String] { lock.withLock { echoes } }
    var resultCount: Int { lock.withLock { results } }
}

func wait(_ what: String, seconds: Double = 8, until condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    log("timed out waiting for \(what)")
    return false
}

let session = Session(
    configuration: SessionConfiguration(
        workingDirectory: workDir, model: model, permissionMode: .default, sessionId: UUID().uuidString.lowercased(),
        binaryPath: env["CLAUDE_BINARY_PATH"],
        systemPrompt: .custom("You are a smoke harness. Answer briefly. Do nothing on your own."),
        inheritsParentEnvironment: true))

_ = Task {
    try await Task.sleep(for: .seconds(timeoutSeconds))
    log("FAIL  timed out; work dir \(workDir.path)")
    exit(1)
}

log("model=\(model) workDir=\(workDir.path)")
let seen = Seen()
let consumer = Task { [events = session.events] in
    for await event in events { seen.record(event) }
}

do {
    let initialized = try await session.start()
    check(!initialized.models.isEmpty, "initialize lists models (\(initialized.models.map(\.value)))")
    check(
        initialized.models.contains { $0.resolvedModel != nil }, "an alias row carries resolvedModel")
    log(
        "current_model=\(initialized.currentModel ?? "nil") mode=\(initialized.currentPermissionMode?.rawValue ?? "nil")"
    )
    // Only a remote-control attach gets current_model; the stdio handshake does not.
    log("initialize carries current_model: \(initialized.currentModel != nil)")
    check(initialized.currentPermissionMode == .default, "initialize carries current_permission_mode")

    let listed = try await session.listModels()
    check(!listed.isEmpty, "list_models answers the catalog (\(listed.map(\.value)))")
    check(
        Set(initialized.models.map(\.value)).isSubset(of: Set(listed.map(\.value))),
        "list_models includes every selectable model")

    try await session.setPermissionMode(.plan)
    check(await wait("the status for plan") { seen.modes.contains(.plan) }, "set_permission_mode plan sends a status")

    do {
        try await session.setPermissionMode(.bypassPermissions)
        check(false, "bypassPermissions without the launch flag is refused")
    } catch let error as AgentSDKError {
        log("refused: \(error.localizedDescription) code=\(error.refusalCode ?? "nil")")
        check(error.refusalCode == "bypass_not_launched", "the refusal code is bypass_not_launched")
    }

    do {
        try await session.setModel("claude-not-a-model-xyz")
        check(false, "an unknown model is refused")
    } catch let error as AgentSDKError {
        log("refused: \(error.localizedDescription) code=\(error.refusalCode ?? "nil")")
        check(error.refusalCode != nil, "an unknown model's refusal carries an error_code")
    }
    try await session.setModel(model)
    // Informational: the `/model` output is not streamed while idle (2.1.286).
    log(
        "set_model echoed as a /model output within 3 s: \(await wait("the /model echo", seconds: 3) { !seen.modelEchoes.isEmpty })"
    )

    let nobody = try await session.cancelAsyncMessage(uuid: UUID().uuidString.lowercased())
    check(!nobody, "cancel_async_message of an unknown uuid answers false")

    // A prompt sent while a turn runs waits in the queue until the turn ends.
    try await session.setPermissionMode(.default)
    try session.send(UserInput("Count from 1 to 40, one number per line, nothing else."))
    let queued = UserInput("Reply with only: second")
    try await Task.sleep(for: .milliseconds(400))
    try session.send(queued)
    check(await wait("the second prompt queued") { seen.states(of: queued.uuid).contains("queued") }, "it queues")
    let cancelled = try await session.cancelAsyncMessage(uuid: queued.uuid)
    log("lifecycle of the second prompt: \(seen.states(of: queued.uuid))")
    if seen.states(of: queued.uuid).contains("started") {
        log("the second prompt started before it could be cancelled; skipping the true-case check")
    } else {
        check(cancelled, "cancel_async_message of a queued prompt answers true")
        check(
            await wait("the cancelled state") { seen.states(of: queued.uuid).contains("cancelled") },
            "its lifecycle ends cancelled")
    }
    try await session.interrupt()
} catch {
    check(false, "no error thrown (\(error))")
}

await session.close()
await consumer.value
log(
    failures.isEmpty
        ? "LiveControlsSmoke PASS" : "LiveControlsSmoke FAIL (\(failures.count)): \(failures.joined(separator: "; "))")
log("work dir: \(workDir.path)")
exit(failures.isEmpty ? 0 : 1)
