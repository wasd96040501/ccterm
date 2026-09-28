// SettingsSmoke — checks `Settings`, `Session.applySettings(_:)` and
// `Session.settings()` against the real CLI. No prompt is sent: every check
// is a control request, so the run spends no tokens.
//
// Checks, all on the session's own layer (user settings leak into
// `effective`, so it is not compared):
//   - `SessionConfiguration.settings` seeds the layer; an unset key in it is
//     dropped instead of voiding the launch layer;
//   - one apply with EVERY key the SDK catalogs is accepted: no validation
//     errors, and each key reads back unchanged, raw and typed. A catalog
//     type that drifts from the CLI's schema fails here — the CLI answers
//     success and silently ignores the whole layer;
//   - `unset` withdraws a runtime value, falling back to the launch value;
//     `permissions` is replaced as a whole; unmentioned keys stay;
//   - a mistyped raw value voids every runtime value (launch values stay)
//     and is reported in `errors`; fixing it restores them;
//   - `model` switches the session model (`applied.model`); `effortLevel:
//     max` applies (`applied.effort`) without staying in the layer.
// Acceptance by the layer is not proof that a key changes behavior mid-session.
//
//   swift run SettingsSmoke
//
// Env: CLAUDE_BINARY_PATH, SMOKE_MODEL (default claude-haiku-4-5),
// SMOKE_EFFORT_MODEL (a model with `max` effort; default claude-opus-5-5 —
// switched to, never prompted), SMOKE_TIMEOUT_SECONDS (default 120, whole run).
// Work dir (kept): /tmp/ccterm-settings-<timestamp>/.

import AgentSDK
import Foundation

let env = ProcessInfo.processInfo.environment
let model = env["SMOKE_MODEL"] ?? "claude-haiku-4-5"
let effortModel = env["SMOKE_EFFORT_MODEL"] ?? "claude-opus-5-5"
let timeoutSeconds = Int(env["SMOKE_TIMEOUT_SECONDS"] ?? "") ?? 120

let workDir = URL(fileURLWithPath: "/tmp/ccterm-settings-\(Int(Date().timeIntervalSince1970))")
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

func json(_ value: JSONValue?) -> String {
    guard let value, let data = try? JSONEncoder().encode(value) else { return "nil" }
    return String(decoding: data, as: UTF8.self)
}

_ = Task {
    try await Task.sleep(for: .seconds(timeoutSeconds))
    log("FAIL  timed out after \(timeoutSeconds) s; work dir \(workDir.path)")
    exit(1)
}

// MARK: - Launch

var launch = Settings()
launch[.language] = "french"
launch[.fastMode] = false
launch.unset(.outputStyle)

let session = Session(
    configuration: SessionConfiguration(
        workingDirectory: workDir, model: model, sessionId: UUID().uuidString.lowercased(),
        binaryPath: env["CLAUDE_BINARY_PATH"], settings: launch, inheritsParentEnvironment: true))
Task {
    for await event in session.events {
        if case .permissionRequest(let request) = event {
            request.respond(.deny(message: "SettingsSmoke runs no tools"))
        }
    }
}

log("model=\(model) effortModel=\(effortModel) workDir=\(workDir.path)")
do {
    try await session.start()
} catch {
    log("FAIL  start: \(error)")
    exit(1)
}

func snapshot(_ name: String) async -> SettingsSnapshot {
    do {
        let snapshot = try await session.settings()
        log(
            "[\(name)] layers=\(snapshot.layers.map { "\($0.source)" }) applied=\(snapshot.applied) "
                + "errors=\(snapshot.errors.map { "\($0.path): \($0.message)" })")
        return snapshot
    } catch {
        log("FAIL  [\(name)] settings(): \(error)")
        exit(1)
    }
}

func apply(_ name: String, _ settings: Settings) async {
    do {
        try await session.applySettings(settings)
    } catch {
        check(false, "\(name): applySettings succeeds (\(error))")
    }
}

let seeded = await snapshot("launch")
let seededLayer = seeded.layer(.session)
check(seeded.errors.isEmpty, "the launch layer validates")
check(seededLayer?[.language] == "french", "the launch layer holds language")
check(seededLayer?[.fastMode] == false, "the launch layer holds fastMode")
check(seededLayer?["outputStyle"] == nil, "an unset launch key is dropped")

// MARK: - Every cataloged key

var all = Settings()
all[.model] = model
all[.advisorModel] = "claude-opus-5-5"
all[.fallbackModel] = ["claude-sonnet-5"]
all[.effortLevel] = .high
all[.ultracode] = false
all[.fastMode] = false
all[.alwaysThinkingEnabled] = true
all[.showThinkingSummaries] = true
all[.promptCacheTTL] = .fiveMinutes
all[.permissions] = PermissionSettings(
    allow: [PermissionRule(toolName: "Bash", ruleContent: "echo (smoke):*"), PermissionRule(toolName: "Read")],
    deny: [PermissionRule(toolName: "WebFetch")], ask: [PermissionRule(toolName: "Bash", ruleContent: "rm:*")],
    defaultMode: .default, additionalDirectories: [workDir.appendingPathComponent("extra").path],
    disablesBypassPermissionsMode: true, blocksReadsOutsideWorkingDirectories: false)
all[.hooks] = ["Stop": [["hooks": [["type": "command", "command": "true"]]]]]
all[.disableAllHooks] = true
all[.outputStyle] = "default"
all[.language] = "english"
all[.plansDirectory] = "plans"
all[.env] = ["SETTINGS_SMOKE": "1"]
all[.attribution] = AttributionSettings(commit: "smoke", pullRequest: "", includesSessionURL: false)
all[.includeGitInstructions] = false
all[.autoCompactEnabled] = true
all[.autoMemoryEnabled] = false
all[.fileCheckpointingEnabled] = true
all[.promptSuggestionEnabled] = false
all[.todoFeatureEnabled] = true
all[.respectGitignore] = true
all[.bashOutputMaxChars] = 20_000
all[.cleanupPeriodDays] = 30
all[.enableAllProjectMCPServers] = false
all[.enabledMCPJSONServers] = ["smoke-enabled"]
all[.disabledMCPJSONServers] = ["smoke-disabled"]
all[.agent] = "general-purpose"

await apply("every key", all)
let full = await snapshot("every key")
check(full.errors.isEmpty, "every cataloged key validates (\(full.errors.map(\.path)))")
let fullLayer = full.layer(.session) ?? Settings()
check(full.layer(.session) != nil, "the session layer survives")
for (key, value) in all.json.sorted(by: { $0.key < $1.key }) {
    check(fullLayer[key] == value, "\(key) reads back unchanged (sent \(json(value)), got \(json(fullLayer[key])))")
}
check(fullLayer[.permissions] == all[.permissions], "permissions reads back typed")
check(fullLayer[.attribution] == all[.attribution], "attribution reads back typed")
check(fullLayer[.effortLevel] == .high, "effortLevel reads back typed")
check(fullLayer[.promptCacheTTL] == .fiveMinutes, "promptCacheTTL reads back typed")
check(fullLayer[.language] == "english", "a key from the launch layer is replaced")

// MARK: - Merge semantics

var removal = Settings()
removal.unset(.language)
removal.unset(.agent)
removal.unset(.hooks)
removal.unset(.disableAllHooks)
removal[.permissions] = PermissionSettings(allow: [PermissionRule(toolName: "Glob")])
await apply("unset + permissions", removal)
let merged = await snapshot("unset + permissions")
let mergedLayer = merged.layer(.session) ?? Settings()
check(mergedLayer[.language] == "french", "unset falls back to the launch value (\(json(mergedLayer["language"])))")
check(mergedLayer["agent"] == nil, "unset removes a key the launch layer lacks")
check(
    mergedLayer[.permissions] == PermissionSettings(allow: [PermissionRule(toolName: "Glob")]),
    "permissions is replaced as a whole")
check(mergedLayer[.bashOutputMaxChars] == 20_000, "keys not mentioned are kept")

// MARK: - A mistyped raw value

var broken = Settings()
broken["fastMode"] = "not a bool"
await apply("mistyped", broken)
let voided = await snapshot("mistyped")
let voidedLayer = voided.layer(.session) ?? Settings()
check(voidedLayer[.bashOutputMaxChars] == nil, "a mistyped value voids every runtime value")
check(voidedLayer[.language] == "french", "launch values survive a mistyped runtime value")
check(voided.errors.contains { $0.path == "fastMode" }, "the mistyped value is reported in errors")
var fixed = Settings()
fixed[.fastMode] = false
await apply("fixed", fixed)
let restored = await snapshot("fixed")
check(
    restored.errors.isEmpty && restored.layer(.session)?[.bashOutputMaxChars] == 20_000, "fixing it restores the layer")

// MARK: - Runtime values

var switchModel = Settings()
switchModel[.model] = effortModel
await apply("model", switchModel)
var maxEffort = Settings()
maxEffort[.effortLevel] = .max
await apply("max effort", maxEffort)
let runtime = await snapshot("max effort")
check(runtime.applied.model == effortModel, "model switches the session model (\(runtime.applied.model ?? "nil"))")
check(runtime.applied.effort == "max", "effortLevel max applies (\(runtime.applied.effort ?? "nil"))")
check(runtime.layer(.session)?["effortLevel"] == nil, "effortLevel max is not kept in the layer")

await session.close()
log(
    failures.isEmpty
        ? "SettingsSmoke PASS" : "SettingsSmoke FAIL (\(failures.count)): \(failures.joined(separator: "; "))")
log("work dir: \(workDir.path)")
exit(failures.isEmpty ? 0 : 1)
