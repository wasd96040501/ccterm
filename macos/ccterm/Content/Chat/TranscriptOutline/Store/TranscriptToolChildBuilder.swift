import AgentSDK
import Foundation

/// Builds a `ToolGroupBlock.Child` (the reused per-kind tool-body
/// payload) from a raw `ToolUse` plus its paired result. Rewritten (not
/// imported) from the bridge-domain `ToolUseToChild` the SPEC forbids
/// depending on (§3) — it reads the AgentSDK types directly instead of
/// the Session-domain `ToolResultPayload` wrapper:
///
/// - `result`: the `ItemToolResult` block from the paired user message
///   (`content` + `isError`).
/// - `typed`: that message's `toolUseResult` — the typed projection
///   (`ToolUseResult`) carrying the structured stdout / filenames / etc.
///
/// History is always terminal, so labels are staged for both statuses
/// (`label` past, `activeLabel` progressive) exactly as the child's
/// `headerLabel(for:)` expects, even though the outline header node —
/// not the child — is what renders the visible title.
enum TranscriptToolChildBuilder {
    static func make(
        toolUse: ToolUse,
        toolUseId: String,
        result: ItemToolResult?,
        typed: ToolUseResult?
    ) -> ToolGroupBlock.Child {
        let label = TranscriptToolNarration.completedFragment(toolUse) ?? toolUse.caseName
        let activeLabel = TranscriptToolNarration.activeFragment(toolUse) ?? toolUse.caseName
        let id = StableBlockID.derive(StableBlockID.toolChildPrefix, toolUseId)
        let resultObject: ToolUseResultObject? = {
            if case .object(let obj) = typed { return obj }
            return nil
        }()
        // Wrapper-level error text — uniform across every tool kind. On
        // error the CLI returns a plain string (never the typed object),
        // so this is the only body content available for a failed call.
        let err = errorText(result: result)

        switch toolUse {
        case .Read(let v):
            return .read(
                ReadChild(
                    id: id, label: label, activeLabel: activeLabel,
                    filePath: v.input?.filePath ?? "",
                    content: err == nil
                        ? stripCatNPrefix(extractText(from: result)) : nil,
                    errorText: err))

        case .Edit(let v):
            return .fileEdit(
                FileEditChild(
                    id: id, label: label, activeLabel: activeLabel,
                    filePath: v.input?.filePath ?? "",
                    diff: DiffBlock(
                        filePath: v.input?.filePath ?? "",
                        oldString: v.input?.oldString,
                        newString: v.input?.newString ?? ""),
                    errorText: err))

        case .Write(let v):
            let originalFile: String? = {
                if case .Write(let obj, _) = resultObject { return obj.originalFile }
                return nil
            }()
            return .fileEdit(
                FileEditChild(
                    id: id, label: label, activeLabel: activeLabel,
                    filePath: v.input?.filePath ?? "",
                    diff: DiffBlock(
                        filePath: v.input?.filePath ?? "",
                        oldString: originalFile,
                        newString: v.input?.content ?? ""),
                    errorText: err))

        case .Bash(let v):
            let (stdout, stderr): (String?, String?) = {
                if case .Bash(let obj, _) = resultObject { return (obj.stdout, obj.stderr) }
                return (nil, nil)
            }()
            return .bash(
                BashChild(
                    id: id, label: label, activeLabel: activeLabel,
                    command: v.input?.command ?? "",
                    stdout: stdout, stderr: stderr, errorText: err))

        case .Grep(let v):
            let (filenames, content): ([String], String?) = {
                if case .Grep(let obj, _) = resultObject {
                    return (obj.filenames ?? [], obj.content)
                }
                return ([], nil)
            }()
            return .grep(
                GrepChild(
                    id: id, label: label, activeLabel: activeLabel,
                    pattern: v.input?.pattern ?? "",
                    filenames: filenames, content: content, errorText: err))

        case .Glob(let v):
            let (filenames, truncated): ([String], Bool) = {
                if case .Glob(let obj, _) = resultObject {
                    return (obj.filenames ?? [], obj.truncated ?? false)
                }
                return ([], false)
            }()
            return .glob(
                GlobChild(
                    id: id, label: label, activeLabel: activeLabel,
                    pattern: v.input?.pattern ?? "",
                    filenames: filenames, truncated: truncated, errorText: err))

        case .WebFetch(let v):
            let (httpStatus, body): (Int?, String?) = {
                if case .WebFetch(let obj, _) = resultObject { return (obj.code, obj.result) }
                return (nil, nil)
            }()
            return .webFetch(
                WebFetchChild(
                    id: id, label: label, activeLabel: activeLabel,
                    url: v.input?.url ?? "",
                    httpStatus: httpStatus, result: body, errorText: err))

        case .WebSearch(let v):
            let results: [WebSearchChild.Result] = {
                if case .WebSearch(let obj, _) = resultObject, let entries = obj.results {
                    return entries.compactMap { entry -> WebSearchChild.Result? in
                        switch entry {
                        case .object(let r):
                            let first = r.content?.first
                            return WebSearchChild.Result(
                                title: first?.title ?? r.toolUseId ?? "",
                                url: first?.url ?? "",
                                snippet: nil)
                        case .string, .other:
                            return nil
                        }
                    }
                }
                return []
            }()
            return .webSearch(
                WebSearchChild(
                    id: id, label: label, activeLabel: activeLabel,
                    query: v.input?.query ?? v.input?.searchQuery ?? "",
                    results: results, errorText: err))

        case .AskUserQuestion(let v):
            let answers: [String: String]? = {
                if case .AskUserQuestion(let obj, _) = resultObject { return obj.answers }
                return nil
            }()
            let items: [AskUserQuestionChild.Item] = (v.input?.questions ?? []).map { q in
                let key = q.question ?? ""
                return AskUserQuestionChild.Item(question: key, answer: answers?[key])
            }
            return .askUserQuestion(
                AskUserQuestionChild(
                    id: id, label: label, activeLabel: activeLabel,
                    items: items, errorText: err))

        case .Agent(let v):
            let (progress, output): ([String], String?) = {
                if case .Task(let obj, _) = resultObject {
                    let progressTexts = (obj.content ?? []).compactMap { $0.text }
                    let outputTexts = (obj.content ?? []).compactMap { $0.text }
                    return (
                        progressTexts,
                        outputTexts.isEmpty ? nil : outputTexts.joined(separator: "\n\n")
                    )
                }
                return ([], nil)
            }()
            return .agent(
                AgentChild(
                    id: id, label: label, activeLabel: activeLabel,
                    description: v.input?.description ?? v.input?.name ?? "Agent",
                    progress: progress, output: output, errorText: err))

        default:
            return .generic(
                GenericChild(
                    id: id, label: label, activeLabel: activeLabel, errorText: err))
        }
    }

    // MARK: - Result text extraction

    /// Wrapper-level error text for a result that came back with
    /// `is_error == true`, stripped of the `<tool_use_error>` envelope.
    /// `nil` for a successful result or one that carried no text.
    private static func errorText(result: ItemToolResult?) -> String? {
        guard result?.isError == true, let raw = extractText(from: result) else { return nil }
        return stripToolUseErrorEnvelope(raw)
    }

    private static func stripToolUseErrorEnvelope(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let open = "<tool_use_error>"
        let close = "</tool_use_error>"
        guard trimmed.hasPrefix(open), trimmed.hasSuffix(close),
            trimmed.count >= open.count + close.count
        else { return trimmed }
        let inner = trimmed.dropFirst(open.count).dropLast(close.count)
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Concatenate all text-bearing fragments out of an `ItemToolResult`.
    /// Returns `nil` when the result is missing or carries no text.
    private static func extractText(from result: ItemToolResult?) -> String? {
        guard let content = result?.content else { return nil }
        switch content {
        case .string(let s):
            return s.isEmpty ? nil : s
        case .array(let items):
            let parts: [String] = items.compactMap { item in
                if case .text(let t) = item, let s = t.text, !s.isEmpty { return s }
                return nil
            }
            guard !parts.isEmpty else { return nil }
            return parts.joined(separator: "\n")
        case .other:
            return nil
        }
    }

    /// Strip the `<lineNo>\t` prefix the CLI prepends to every Read line
    /// (`cat -n` style); the diff renderer rebuilds its own gutter
    /// numbers. `nil` in → `nil` out so the "no body yet" signal survives.
    private static func stripCatNPrefix(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        let stripped = lines.map { line -> String in
            let s = line
            var idx = s.startIndex
            while idx < s.endIndex, s[idx] == " " { idx = s.index(after: idx) }
            let digitsStart = idx
            while idx < s.endIndex, s[idx].isASCII, s[idx].isNumber {
                idx = s.index(after: idx)
            }
            guard idx > digitsStart, idx < s.endIndex, s[idx] == "\t" else {
                return String(s)
            }
            return String(s[s.index(after: idx)...])
        }
        return stripped.joined(separator: "\n")
    }
}
