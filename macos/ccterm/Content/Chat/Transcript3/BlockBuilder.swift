import AgentSDK
import Foundation

/// Pure function namespace that turns a slice of `[Message2]` into
/// `[T3Block]`. No I/O, no state, no side effects — same input, same output.
///
/// Filtering, grouping (consecutive tool_use / tool_result run → one
/// `.toolGroup`), and tool_use ↔ tool_result pairing all live here.
/// Called on the main actor from `TranscriptStore.ingest(_:)`; testable
/// directly by feeding a `[Message2]` fixture and comparing the result.
///
/// The `prior` parameter is the message list already ingested by the
/// Store, in document order (oldest → newest). It only affects the very
/// first block of the new batch: if the tail of `prior` was inside a
/// tool run and the head of `batch` continues that run, we don't
/// materialise a fresh group — the caller re-materialises the merged
/// group instead. (First-pass implementation is simpler: each call builds
/// its own contiguous groups; overlap across batches is left to Store,
/// which currently just concatenates. This mirrors the coarser grouping
/// the old bridge did; parity-tighter grouping lands with the live path.)
public enum BlockBuilder {

    public static func build(from batch: [Message2], prior _: [Message2]) -> [T3Block] {
        var out: [T3Block] = []
        var pendingCalls: [T3Block.ToolCall] = []
        var pendingId: UUID = UUID()

        // Resolve `tool_use_id → ToolOutput` from user tool_result messages in
        // this batch. The SDK's reverse pairer already emits paired messages
        // in document order, so scanning once produces the map cheaply.
        var outputs: [String: T3Block.ToolOutput] = [:]
        for m in batch {
            if case .user(let u) = m {
                for (id, output) in u.toolOutputs { outputs[id] = output }
            }
        }

        func flushToolGroup() {
            guard !pendingCalls.isEmpty else { return }
            if pendingCalls.count == 1 {
                out.append(T3Block(id: pendingId, kind: .toolCall(pendingCalls[0])))
            } else {
                out.append(T3Block(id: pendingId, kind: .toolGroup(calls: pendingCalls)))
            }
            pendingCalls.removeAll(keepingCapacity: true)
            pendingId = UUID()
        }

        for m in batch {
            switch m {
            case .assistant(let a):
                let blocks = a.message?.content ?? []
                let toolUses = blocks.compactMap { block -> ToolUse? in
                    if case .toolUse(let u) = block { return u }
                    return nil
                }
                let texts = blocks.compactMap { block -> String? in
                    if case .text(let t) = block, let s = t.text, !s.isEmpty { return s }
                    return nil
                }
                // Groupable assistant (all tool_use, no text) → collect
                // into the currently-open tool group.
                if !toolUses.isEmpty && texts.isEmpty {
                    for use in toolUses {
                        pendingCalls.append(makeToolCall(from: use, outputs: outputs))
                    }
                    continue
                }
                // Mixed / text-only assistant closes any open tool group,
                // then emits paragraphs (and any inline tool_use as its own
                // toolCall block after the text — parity with the old bridge).
                flushToolGroup()
                for t in texts {
                    out.append(T3Block(kind: .assistantText(t)))
                }
                for use in toolUses {
                    let call = makeToolCall(from: use, outputs: outputs)
                    out.append(T3Block(kind: .toolCall(call)))
                }

            case .user(let u):
                // Tool-result-only user messages are absorbed by the tool
                // group whose tool_use they pair with — no standalone block.
                if u.isPureToolResult { continue }
                // Any other visible user closes an open tool group.
                flushToolGroup()
                if let text = u.plainText {
                    out.append(
                        T3Block(
                            kind: .userBubble(text: text, attachments: u.attachments)))
                }

            default:
                continue
            }
        }
        flushToolGroup()
        return out
    }

    // MARK: - Tool call construction

    private static func makeToolCall(
        from use: ToolUse,
        outputs: [String: T3Block.ToolOutput]
    ) -> T3Block.ToolCall {
        let name = use.displayName
        let summary = use.inputSummary
        let id = use.id
        let output = id.flatMap { outputs[$0] }
        return T3Block.ToolCall(name: name, inputSummary: summary, output: output)
    }
}

// MARK: - Message2 helpers (module-internal)

extension Message2User {

    /// True when the user message's only visible content is a tool_result
    /// (i.e. it exists purely to close a tool call). The block builder
    /// filters these out — they're absorbed into the adjacent tool group.
    fileprivate var isPureToolResult: Bool {
        guard case .array(let items) = message?.content else { return false }
        var hasToolResult = false
        var hasOtherVisible = false
        for item in items {
            switch item {
            case .toolResult:
                hasToolResult = true
            case .text(let t) where !(t.text?.isEmpty ?? true):
                hasOtherVisible = true
            case .image:
                hasOtherVisible = true
            default:
                continue
            }
        }
        return hasToolResult && !hasOtherVisible
    }

    /// Flat text extracted from either string-shaped or array-shaped
    /// content. Returns nil when the message has no visible text at all
    /// (e.g. attachment-only user turns render an empty bubble; the
    /// builder decides whether to emit that or not via `attachments`).
    fileprivate var plainText: String? {
        switch message?.content {
        case .string(let s)?:
            return s.isEmpty ? nil : s
        case .array(let items)?:
            var parts: [String] = []
            for item in items {
                if case .text(let t) = item, let s = t.text, !s.isEmpty {
                    parts.append(s)
                }
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        default:
            return nil
        }
    }

    /// User's inline image attachments. Empty when no image blocks.
    fileprivate var attachments: [T3ImageSource] {
        guard case .array(let items) = message?.content else { return [] }
        var out: [T3ImageSource] = []
        for item in items {
            if case .image(let img) = item, let url = img.source {
                if let u = URL(string: url) {
                    out.append(u.isFileURL ? .file(u) : .remote(u))
                }
            }
        }
        return out
    }

    /// `[tool_use_id: ToolOutput]` pairs harvested from this user message's
    /// tool_result blocks. Empty when the message has no tool_results.
    fileprivate var toolOutputs: [(String, T3Block.ToolOutput)] {
        guard case .array(let items) = message?.content else { return [] }
        var out: [(String, T3Block.ToolOutput)] = []
        for item in items {
            if case .toolResult(let r) = item, let id = r.toolUseId {
                out.append((id, T3Block.ToolOutput(text: r.plainText, isError: r.isError ?? false)))
            }
        }
        return out
    }
}

extension ItemToolResult {

    fileprivate var plainText: String {
        switch content {
        case .string(let s)?:
            return s
        case .array(let items)?:
            var parts: [String] = []
            for item in items {
                if case .text(let t) = item, let s = t.text, !s.isEmpty {
                    parts.append(s)
                }
            }
            return parts.joined(separator: "\n")
        default:
            return ""
        }
    }
}

extension Image {
    fileprivate var source: String? {
        // Best-effort: pull whichever URL/data-url shape the AgentSDK
        // Image struct exposes. When the SDK's Image doesn't carry a URL,
        // the block builder skips it — reference resolution isn't the
        // model's job.
        if let raw = _raw["source"] as? [String: Any] {
            if let url = raw["url"] as? String { return url }
            if let data = raw["data"] as? String, let media = raw["media_type"] as? String {
                return "data:\(media);base64,\(data)"
            }
        }
        return _raw["url"] as? String
    }
}

extension ToolUse {

    /// Human-readable tool name (`Bash`, `Read`, `Edit`, …). Matches the
    /// case name — the SDK's generator already keeps them display-clean.
    fileprivate var displayName: String {
        switch self {
        case .Agent: return "Agent"
        case .AskUserQuestion: return "AskUserQuestion"
        case .Bash: return "Bash"
        case .CronCreate: return "CronCreate"
        case .Edit: return "Edit"
        case .EnterPlanMode: return "EnterPlanMode"
        case .EnterWorktree: return "EnterWorktree"
        case .ExitPlanMode: return "ExitPlanMode"
        case .ExitWorktree: return "ExitWorktree"
        case .Glob: return "Glob"
        case .Grep: return "Grep"
        case .Read: return "Read"
        case .SendMessage: return "SendMessage"
        case .Skill: return "Skill"
        case .Task: return "Task"
        case .TaskCreate: return "TaskCreate"
        case .TaskOutput: return "TaskOutput"
        case .TaskStop: return "TaskStop"
        case .TaskUpdate: return "TaskUpdate"
        case .TeamCreate: return "TeamCreate"
        case .TodoWrite: return "TodoWrite"
        case .ToolSearch: return "ToolSearch"
        case .WebFetch: return "WebFetch"
        case .WebSearch: return "WebSearch"
        case .Write: return "Write"
        case .unknown(let name, _): return name
        }
    }

    /// Tool call id — every ToolUse variant carries an `id` string on its
    /// payload struct. Lookup goes through `_raw` for a uniform path
    /// without pattern-matching every case.
    fileprivate var id: String? {
        _rawDict["id"] as? String
    }

    /// One-line input summary suitable for the collapsed tool row. Picks
    /// the field that's most descriptive per tool; falls back to a JSON
    /// preview of the input dictionary.
    fileprivate var inputSummary: String {
        let input = _rawDict["input"] as? [String: Any] ?? [:]
        switch self {
        case .Bash: return input["command"] as? String ?? ""
        case .Read: return input["file_path"] as? String ?? ""
        case .Edit: return input["file_path"] as? String ?? ""
        case .Write: return input["file_path"] as? String ?? ""
        case .Glob: return input["pattern"] as? String ?? ""
        case .Grep: return input["pattern"] as? String ?? ""
        case .WebFetch: return input["url"] as? String ?? ""
        case .WebSearch: return input["query"] as? String ?? ""
        case .Skill: return input["skill"] as? String ?? ""
        default:
            if let s = input["description"] as? String, !s.isEmpty { return s }
            if let s = input["command"] as? String, !s.isEmpty { return s }
            return input.isEmpty ? "" : "…"
        }
    }

    private var _rawDict: [String: Any] {
        switch self {
        case .Agent(let x): return x._raw
        case .AskUserQuestion(let x): return x._raw
        case .Bash(let x): return x._raw
        case .CronCreate(let x): return x._raw
        case .Edit(let x): return x._raw
        case .EnterPlanMode(let x): return x._raw
        case .EnterWorktree(let x): return x._raw
        case .ExitPlanMode(let x): return x._raw
        case .ExitWorktree(let x): return x._raw
        case .Glob(let x): return x._raw
        case .Grep(let x): return x._raw
        case .Read(let x): return x._raw
        case .SendMessage(let x): return x._raw
        case .Skill(let x): return x._raw
        case .Task(let x): return x._raw
        case .TaskCreate(let x): return x._raw
        case .TaskOutput(let x): return x._raw
        case .TaskStop(let x): return x._raw
        case .TaskUpdate(let x): return x._raw
        case .TeamCreate(let x): return x._raw
        case .TodoWrite(let x): return x._raw
        case .ToolSearch(let x): return x._raw
        case .WebFetch(let x): return x._raw
        case .WebSearch(let x): return x._raw
        case .Write(let x): return x._raw
        case .unknown(_, let raw): return raw
        }
    }
}
