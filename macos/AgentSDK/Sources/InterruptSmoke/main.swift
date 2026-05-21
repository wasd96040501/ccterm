import AgentSDK
import Foundation

// Real-CLI smoke for "interrupt mid-stream duplicates the user message".
// Spawns haiku, sends a long-running prompt with a known uuid, waits for
// the assistant stream to start, calls session.interrupt(), then drains
// post-interrupt traffic and reports:
//
//   - count of user-message echoes whose uuid matches the one we sent
//     (the bug: this is > 1)
//   - count of synthetic "[Request interrupted by user]" user messages
//   - whether any user echo carries `isSidechain` / `parentToolUseId`
//     (filtered by SessionRuntime.receive's isVisible check)
//
// Run from `macos/AgentSDK`:
//
//   swift run InterruptSmoke
//
// Env: CLAUDE_BINARY_PATH (override), SMOKE_MODEL (default
// claude-haiku-4-5), SMOKE_PROMPT (default a long-bedtime-story
// prompt).

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
    ?? ("Write a long bedtime story about a robot exploring Mars. "
        + "Aim for at least 800 words. Take your time and be descriptive.")
guard let claudeBin = locateClaude() else {
    log("ERROR: no claude binary found")
    exit(1)
}

let stamp = Int(Date().timeIntervalSince1970)
let workDir = URL(fileURLWithPath: "/tmp/ccterm-interrupt-smoke-\(stamp)", isDirectory: true)
let exportDir = workDir.appendingPathComponent("export", isDirectory: true)
try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

let sessionId = UUID().uuidString.lowercased()
let userUUID = UUID().uuidString.lowercased()

log("workDir=\(workDir.path)")
log("model=\(model) sessionId=\(sessionId) userUUID=\(userUUID)")

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

// Bug-relevant counters.
var totalAssistantMessages = 0
var totalUserMessagesAll = 0
var userEchoesMatchingOurUUID = 0
var userEchoesOtherUUID = 0
var syntheticInterruptUserCount = 0
var processExitCode: Int32? = nil

let interruptAcked = DispatchSemaphore(value: 0)
let firstAssistantSeen = DispatchSemaphore(value: 0)
var firstAssistantTripped = false
let processExited = DispatchSemaphore(value: 0)

session.onMessage = { (message: Message2) in
    switch message {
    case .assistant(let a):
        totalAssistantMessages += 1
        let textBlocks: [String] =
            (a.message?.content ?? []).compactMap { block in
                if case .text(let t) = block, let txt = t.text, !txt.isEmpty {
                    return String(txt.prefix(40))
                }
                return nil
            }
        log("[asst #\(totalAssistantMessages)] text=\(textBlocks)")
        if !firstAssistantTripped, !textBlocks.isEmpty {
            firstAssistantTripped = true
            firstAssistantSeen.signal()
        }
    case .user(let u):
        totalUserMessagesAll += 1
        // What text does it carry?
        var snippet = ""
        switch u.message?.content {
        case .string(let s): snippet = String(s.prefix(80))
        case .array(let items):
            let texts: [String] = items.compactMap {
                if case .text(let t) = $0 { return t.text }
                return nil
            }
            snippet = String(texts.joined(separator: "|").prefix(80))
        default: snippet = "(none)"
        }
        let isInterruptSynthetic = snippet.contains("[Request interrupted by user]")
        if isInterruptSynthetic { syntheticInterruptUserCount += 1 }
        let echoUUIDMatches = (u.uuid?.lowercased() == userUUID)
        if echoUUIDMatches {
            userEchoesMatchingOurUUID += 1
        } else {
            // Skip tool_result-only user messages (those carry tool_use_id).
            let allToolResults: Bool = {
                if case .array(let items) = u.message?.content {
                    return !items.isEmpty
                        && items.allSatisfy {
                            if case .toolResult = $0 { return true }
                            return false
                        }
                }
                return false
            }()
            if !allToolResults && !isInterruptSynthetic {
                userEchoesOtherUUID += 1
            }
        }
        log(
            "[user #\(totalUserMessagesAll)] uuid=\(u.uuid?.prefix(8) ?? "(nil)") "
                + "match-ours=\(echoUUIDMatches) synth=\(isInterruptSynthetic) "
                + "parentTool=\(u.parentToolUseId ?? "(nil)") "
                + "text=\(snippet)"
        )
    case .result(let r):
        log("[result] \(r)")
    case .system(.`init`):
        log("[system.init]")
    default:
        break
    }
}
session.onStderr = { text in
    log("[stderr] \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
}
session.onProcessExit = { code in
    log("[exit] code=\(code)")
    processExitCode = code
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

log("sending prompt with uuid=\(userUUID)…")
session.sendMessage(prompt, extra: ["uuid": userUUID])

// Interrupt window: env `INTERRUPT_AFTER_MS` (default 1500). We do NOT
// wait for the first assistant text — for fast models (haiku) the turn
// can finish in <5s, and the bug only manifests if interrupt lands
// mid-turn (entry not yet `.confirmed`, or assistant still streaming).
let afterMs = Int(env["INTERRUPT_AFTER_MS"] ?? "1500") ?? 1500
log("waiting \(afterMs)ms then calling interrupt regardless of assistant state")
Thread.sleep(forTimeInterval: TimeInterval(afterMs) / 1000.0)

log("calling session.interrupt() — totalAssistantMessages seen so far=\(totalAssistantMessages)")
session.interrupt { _ in
    log("interrupt ack")
    interruptAcked.signal()
}
if interruptAcked.wait(timeout: .now() + 10) == .timedOut {
    log("WARN interrupt ack did not arrive within 10s — continuing anyway")
}

// Drain post-interrupt traffic. The CLI may still emit additional
// messages (synthetic interrupt user, late assistant, .result, …).
log("drain window 6s")
Thread.sleep(forTimeInterval: 6)

log("closing session")
session.close()
if processExited.wait(timeout: .now() + 10) == .timedOut {
    log("WARN process did not exit within 10s of close")
}

// Final report.
log("=== REPORT ===")
log("totalAssistantMessages=\(totalAssistantMessages)")
log("totalUserMessages=\(totalUserMessagesAll)")
log("userEchoesMatchingOurUUID=\(userEchoesMatchingOurUUID)  (>1 = duplicate bug)")
log("userEchoesOtherUUID=\(userEchoesOtherUUID)")
log("syntheticInterruptUserCount=\(syntheticInterruptUserCount)")
log("processExitCode=\(processExitCode.map(String.init) ?? "nil")")
log("workDir=\(workDir.path) (export at \(exportDir.path))")

if let files = try? FileManager.default.contentsOfDirectory(at: exportDir, includingPropertiesForKeys: nil) {
    for url in files {
        log("export file: \(url.path)")
    }
}

if userEchoesMatchingOurUUID > 1 {
    log("REPRODUCED: CLI re-emitted our user message — bug is on the CLI side")
    exit(2)
}
log("done")
