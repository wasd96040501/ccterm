import AgentSDK
import Foundation

/// Converts `ToolUse + ToolResultPayload` into a `ToolGroupBlock.Child`.
///
/// Same dispatch shape as the legacy `ToolBlockView`, but the output is the
/// native transcript's per-kind child struct: each child carries a stable
/// `id` (derived via StableBlockID from toolUseId), a display `label`, and
/// the fields needed for rendering.
enum ToolUseToChild {
    /// `toolUseId` uniquely identifies this tool invocation across child id /
    /// fold-state / highlight scope. `result` comes from
    /// `SingleEntry.toolResults[toolUseId]`.
    ///
    /// Label policy: **fill both** (`label` = past tense, `activeLabel` =
    /// progressive). The layout selects between them based on `ToolStatus` —
    /// `.running` picks `activeLabel`, terminal states pick `label`. The
    /// bridge no longer toggles a single value via `hasResult`; status flows
    /// through the independent `setToolStatus` channel and the bridge just
    /// stages both labels.
    static func make(
        toolUse: ToolUse,
        toolUseId: String,
        result: ToolResultPayload?
    ) -> ToolGroupBlock.Child {
        let label = toolUse.completedFragment ?? toolUse.caseName
        let activeLabel = toolUse.activeFragment ?? toolUse.caseName
        let id = StableBlockID.derive("tool", toolUseId)
        let resultObject: ToolUseResultObject? = {
            if case .object(let obj) = result?.typed { return obj }
            return nil
        }()
        // Wrapper-level error text — uniform across every tool kind.
        // On error the CLI returns a plain string (never the typed
        // object — see `Transcript2EntryBridge`'s status table), so this
        // is the only body content available for a failed call.
        let err = errorText(from: result)

        switch toolUse {
        case .Read(let v):
            return .read(
                ReadChild(
                    id: id,
                    label: label,
                    activeLabel: activeLabel,
                    filePath: v.input?.filePath ?? "",
                    // On error, `extractText` would otherwise pour the
                    // error string into the new-file diff card; suppress
                    // it so only the dedicated red error card shows.
                    content: err == nil
                        ? stripCatNPrefix(extractText(from: result)) : nil,
                    errorText: err))

        case .Edit(let v):
            return .fileEdit(
                FileEditChild(
                    id: id,
                    label: label,
                    activeLabel: activeLabel,
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
                    id: id,
                    label: label,
                    activeLabel: activeLabel,
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
                    id: id,
                    label: label,
                    activeLabel: activeLabel,
                    command: v.input?.command ?? "",
                    stdout: stdout,
                    stderr: stderr,
                    errorText: err))

        case .Grep(let v):
            let (filenames, content): ([String], String?) = {
                if case .Grep(let obj, _) = resultObject {
                    return (obj.filenames ?? [], obj.content)
                }
                return ([], nil)
            }()
            return .grep(
                GrepChild(
                    id: id,
                    label: label,
                    activeLabel: activeLabel,
                    pattern: v.input?.pattern ?? "",
                    filenames: filenames,
                    content: content,
                    errorText: err))

        case .Glob(let v):
            let (filenames, truncated): ([String], Bool) = {
                if case .Glob(let obj, _) = resultObject {
                    return (obj.filenames ?? [], obj.truncated ?? false)
                }
                return ([], false)
            }()
            return .glob(
                GlobChild(
                    id: id,
                    label: label,
                    activeLabel: activeLabel,
                    pattern: v.input?.pattern ?? "",
                    filenames: filenames,
                    truncated: truncated,
                    errorText: err))

        case .WebFetch(let v):
            let (httpStatus, body): (Int?, String?) = {
                if case .WebFetch(let obj, _) = resultObject { return (obj.code, obj.result) }
                return (nil, nil)
            }()
            return .webFetch(
                WebFetchChild(
                    id: id,
                    label: label,
                    activeLabel: activeLabel,
                    url: v.input?.url ?? "",
                    httpStatus: httpStatus,
                    result: body,
                    errorText: err))

        case .WebSearch(let v):
            let results: [WebSearchChild.Result] = {
                if case .WebSearch(let obj, _) = resultObject,
                    let entries = obj.results
                {
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
                    id: id,
                    label: label,
                    activeLabel: activeLabel,
                    query: v.input?.query ?? v.input?.searchQuery ?? "",
                    results: results,
                    errorText: err))

        case .AskUserQuestion(let v):
            let answers: [String: String]? = {
                if case .AskUserQuestion(let obj, _) = resultObject { return obj.answers }
                return nil
            }()
            let items: [AskUserQuestionChild.Item] = (v.input?.questions ?? []).map { q in
                let key = q.question ?? ""
                return AskUserQuestionChild.Item(
                    question: key,
                    answer: answers?[key])
            }
            return .askUserQuestion(
                AskUserQuestionChild(
                    id: id,
                    label: label,
                    activeLabel: activeLabel,
                    items: items,
                    errorText: err))

        case .Agent(let v):
            let (progress, output): ([String], String?) = {
                if case .Task(let obj, _) = resultObject {
                    let progressTexts = (obj.content ?? []).compactMap { $0.text }
                    let outputTexts = (obj.content ?? []).compactMap { $0.text }
                    return (progressTexts, outputTexts.isEmpty ? nil : outputTexts.joined(separator: "\n\n"))
                }
                return ([], nil)
            }()
            return .agent(
                AgentChild(
                    id: id,
                    label: label,
                    activeLabel: activeLabel,
                    description: v.input?.description ?? v.input?.name ?? "Agent",
                    progress: progress,
                    output: output,
                    errorText: err))

        default:
            return .generic(
                GenericChild(
                    id: id, label: label, activeLabel: activeLabel,
                    errorText: err))
        }
    }

    /// Wrapper-level error text for a result that came back with
    /// `is_error == true`. The CLI delivers the message as a plain string
    /// (it never populates the typed result object on error — see the
    /// status table in `Transcript2EntryBridge`), sometimes wrapped in a
    /// `<tool_use_error>…</tool_use_error>` envelope which we strip so the
    /// card shows just the message. Returns `nil` for a successful result
    /// or one that carried no text.
    private static func errorText(from result: ToolResultPayload?) -> String? {
        guard result?.isError == true,
            let raw = extractText(from: result)
        else { return nil }
        return stripToolUseErrorEnvelope(raw)
    }

    /// Drop a surrounding `<tool_use_error>…</tool_use_error>` envelope
    /// (the form the CLI uses for input-validation / path-not-found
    /// failures) and trim surrounding whitespace. Plain error strings
    /// (permission denials, non-zero exits, HTTP errors) pass through
    /// unchanged save for the trim.
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

    /// Concatenate all text-bearing fragments out of a `ToolResultPayload`.
    /// Returns `nil` when the result is missing or carries no text (image-
    /// only / unknown shapes), so callers can distinguish "not landed yet"
    /// from "landed empty".
    private static func extractText(from result: ToolResultPayload?) -> String? {
        guard let content = result?.item.content else { return nil }
        switch content {
        case .string(let s):
            return s.isEmpty ? nil : s
        case .array(let items):
            let parts: [String] = items.compactMap { item in
                if case .text(let t) = item, let s = t.text, !s.isEmpty {
                    return s
                }
                return nil
            }
            guard !parts.isEmpty else { return nil }
            return parts.joined(separator: "\n")
        case .other:
            return nil
        }
    }

    /// Strip the `<lineNo>\t` prefix the CLI prepends to every Read
    /// line (`cat -n` style). The diff renderer reconstructs its own
    /// gutter numbers from the line index, so leaving the originals in
    /// would print them twice. Returns `nil` when the input is nil so
    /// callers can keep the "no body yet" signal.
    private static func stripCatNPrefix(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        let stripped = lines.map { line -> String in
            let s = line
            // Skip leading whitespace, then digits, then a single tab —
            // the format used by the Read tool. Anything else leaves
            // the line untouched (so non-Read shapes pass through).
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
