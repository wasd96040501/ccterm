// TranscriptSmoke — checks `Transcript`'s contract against the real CLI:
// reading a session's file gives the conversation a live `Session` emitted.
//
// One session, driven through what shapes a file: a response with parallel
// tool calls, a rewind to an earlier prompt (`rewindConversation(to:)`, as an
// edited prompt does), `/compact`, and a resume in a second process. After
// each step the file is read with `Transcript` and compared with the
// `.user` / `.assistant` / compaction-boundary messages received live, minus
// what the rewind took back. A mismatch prints both sides.
//
//   swift run TranscriptSmoke
//
// Env: CLAUDE_BINARY_PATH, SMOKE_MODEL (default claude-haiku-4-5).
// Work dir (kept): /tmp/ccterm-transcript-<timestamp>/.

import AgentSDK
import Foundation

let env = ProcessInfo.processInfo.environment
let model = env["SMOKE_MODEL"] ?? "claude-haiku-4-5"
let workDir = URL(fileURLWithPath: "/tmp/ccterm-transcript-\(Int(Date().timeIntervalSince1970))")
try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
let sessionID = UUID().uuidString.lowercased()

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
}

var failures: [String] = []

func check(_ ok: Bool, _ what: String) {
    log("\(ok ? "PASS" : "FAIL")  \(what)")
    if !ok { failures.append(what) }
}

/// A conversation message as the contract compares it; `nil` for what is
/// not part of the conversation.
func key(_ message: Message) -> String? {
    func json(_ content: [ContentBlock]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(content)) ?? Data(), as: UTF8.self)
    }
    switch message {
    case .user(let m): return "user \(m.uuid ?? "-") \(json(m.content))"
    case .assistant(let m): return "assistant \(m.uuid) \(json(m.content))"
    case .system(.compactBoundary(let b)): return "boundary \(b.trigger) \(b.preTokens)"
    default: return nil
    }
}

/// One CLI process: sends prompts and keeps the conversation it emits.
final class Run {
    let session: Session
    private var events: AsyncStream<SessionEvent>.AsyncIterator
    private(set) var conversation: [Message] = []

    init(resume: Bool) {
        session = Session(
            configuration: SessionConfiguration(
                workingDirectory: workDir, model: model, sessionId: resume ? nil : sessionID,
                resume: resume ? sessionID : nil, binaryPath: env["CLAUDE_BINARY_PATH"],
                inheritsParentEnvironment: true))
        events = session.events.makeAsyncIterator()
    }

    /// Sends `text` and reads until its turn's result. A local command's
    /// echo arrives after its output; the contract puts the command first.
    func turn(_ text: String) async throws -> UserInput {
        let input = UserInput(text)
        try session.send(input)
        var output: Int?
        while let event = await events.next() {
            switch event {
            case .message(.result(let result)):
                log("turn \(text.prefix(40).debugDescription) → \(result.subtype.rawValue)")
                return input
            case .message(.user(let m)) where m.isReplay && m.uuid == input.uuid && output != nil:
                conversation.insert(.user(m), at: output!)
            case .message(.user(let m)) where m.isReplay && m.kind.isCommandOutput:
                output = output ?? conversation.count
                conversation.append(.user(m))
            case .message(let message):
                if key(message) != nil { conversation.append(message) }
            case .permissionRequest(let request):
                request.respond(.allow())
            case .permissionRequestCancelled, .exited:
                break
            }
        }
        throw AgentSDKError.processExited(Termination(exitCode: -1, stderr: "events ended mid-turn"))
    }

    /// Takes the conversation back to before `prompt`, as editing it does.
    /// The CLI refuses while the turn it just reported is still winding
    /// down (`turn_running`), so this retries for a few seconds.
    func rewind(to prompt: UserInput) async throws {
        var response = RewindResult(rewound: false)
        for _ in 0..<50 {
            response = try await session.rewindConversation(to: prompt.uuid)
            guard response.reason == "turn_running" else { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        log("rewind → \(response)")
        guard response.rewound else {
            throw AgentSDKError.invalidResponse(subtype: "rewind_conversation")
        }
        if let cut = conversation.firstIndex(where: { key($0)?.hasPrefix("user \(prompt.uuid) ") == true }) {
            conversation.removeSubrange(cut...)
        }
    }

    func close() async {
        await session.close()
        while let event = await events.next() {
            if case .message(let message) = event, key(message) != nil { conversation.append(message) }
        }
    }
}

extension UserMessage.Kind {
    var isCommandOutput: Bool {
        if case .commandOutput = self { return true }
        return false
    }
}

/// Compares the file, read now, with what was seen live.

func compare(_ expected: [Message], _ step: String) {
    guard let file = SessionDirectory(environment: env).sessions().first(where: { $0.id == sessionID }) else {
        return check(false, "\(step): the session's file exists")
    }
    let read: [String]
    do {
        read = try Transcript(contentsOf: file.url).messages.compactMap(key)
    } catch {
        return check(false, "\(step): the file reads (\(error))")
    }
    let live = expected.compactMap(key)
    check(read == live, "\(step): the file reads as the live conversation (\(read.count) vs \(live.count) messages)")
    guard read != live else { return }
    for index in 0..<max(read.count, live.count) {
        let r = index < read.count ? read[index] : "—"
        let l = index < live.count ? live[index] : "—"
        log("  \(r == l ? " " : "≠") \(index)")
        log("      file: \(r.prefix(200))")
        if r != l { log("      live: \(l.prefix(200))") }
    }
}

_ = Task {
    try await Task.sleep(for: .seconds(600))
    log("FAIL  timed out after 600 s; work dir \(workDir.path)")
    exit(1)
}

log("model=\(model) session=\(sessionID) workDir=\(workDir.path)")
do {
    let first = Run(resume: false)
    _ = try await first.session.start()

    _ = try await first.turn(
        "In one response, make two Bash tool calls in parallel: `echo one` and `echo two`. "
            + "Then reply with exactly: done")
    compare(first.conversation, "parallel tool calls")

    let abandoned = try await first.turn("Reply with exactly: second")
    try await first.rewind(to: abandoned)
    _ = try await first.turn("Reply with exactly: edited")
    compare(first.conversation, "rewind")

    _ = try await first.turn("/compact")
    let commands = first.conversation.compactMap { message -> UserMessage.Kind? in
        guard case .user(let m) = message else { return nil }
        switch m.kind {
        case .slashCommand, .commandOutput: return m.kind
        default: return nil
        }
    }
    check(
        commands.first == .slashCommand(name: "/compact", arguments: ""),
        "/compact reads as a local command (\(commands))")
    check(commands.dropFirst().first?.isCommandOutput == true, "its output reads as the command's output")
    _ = try await first.turn("Reply with exactly: after compact")
    await first.close()
    compare(first.conversation, "compaction")

    let second = Run(resume: true)
    _ = try await second.session.start()
    _ = try await second.turn("Reply with exactly: resumed")
    await second.close()
    log("resume emitted \(second.conversation.count) conversation messages")
    compare(first.conversation + second.conversation, "resume")
} catch {
    log("FAIL  \(error)")
    failures.append("\(error)")
}

log(
    failures.isEmpty
        ? "TranscriptSmoke PASS" : "TranscriptSmoke FAIL (\(failures.count)): \(failures.joined(separator: "; "))")
log("work dir: \(workDir.path)")
exit(failures.isEmpty ? 0 : 1)
