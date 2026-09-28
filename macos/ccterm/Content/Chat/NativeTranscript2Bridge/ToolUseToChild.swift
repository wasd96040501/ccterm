import AgentSDK
import Foundation

/// Converts a tool call and its result into a `ToolGroupBlock.Child`.
///
/// Each child carries a stable `id` (derived via StableBlockID from
/// toolUseId), a display `label`, and the fields needed for rendering.
enum ToolUseToChild {
    /// `toolUseId` uniquely identifies this tool invocation across child id /
    /// fold-state / highlight scope. `result` is the call's
    /// `SingleEntry.toolResults` entry.
    ///
    /// Label policy: **fill both** (`label` = past tense, `activeLabel` =
    /// progressive). The layout selects between them based on `ToolStatus` —
    /// `.running` picks `activeLabel`, terminal states pick `label`; status
    /// flows through the separate `setToolStatus` channel.
    static func make(
        toolUse: ToolUseBlock,
        toolUseId: String,
        result: UserMessage?
    ) -> ToolGroupBlock.Child {
        let label = toolUse.completedFragment ?? toolUse.name
        let activeLabel = toolUse.activeFragment ?? toolUse.name
        let id = StableBlockID.derive(StableBlockID.toolChildPrefix, toolUseId)
        // Wrapper-level error text — uniform across every tool kind. On
        // error the CLI returns a plain string, never the structured output
        // (see `Transcript2EntryBridge`'s status table), so this is the only
        // body content available for a failed call.
        let err = errorText(from: result)

        /// The structured output, when the call succeeded.
        func output<T: ToolDefinition>(_ tool: T.Type) -> T.Output? {
            if case .success(let value)? = result?.toolOutcome(tool) { return value }
            return nil
        }

        switch toolUse.groupableKind {
        case .read:
            return .read(
                ReadChild(
                    id: id,
                    label: label,
                    activeLabel: activeLabel,
                    filePath: toolUse.input(as: Tools.Read.self)?.filePath ?? "",
                    // On error, `extractText` would otherwise pour the
                    // error string into the new-file diff card; suppress
                    // it so only the dedicated red error card shows.
                    content: err == nil ? stripCatNPrefix(extractText(from: result)) : nil,
                    errorText: err))

        case .edit:
            let input = toolUse.input(as: Tools.Edit.self)
            return .fileEdit(
                FileEditChild(
                    id: id,
                    label: label,
                    activeLabel: activeLabel,
                    filePath: input?.filePath ?? "",
                    diff: DiffBlock(
                        filePath: input?.filePath ?? "",
                        oldString: input?.oldString,
                        newString: input?.newString ?? ""),
                    errorText: err))

        case .write:
            let input = toolUse.input(as: Tools.Write.self)
            return .fileEdit(
                FileEditChild(
                    id: id,
                    label: label,
                    activeLabel: activeLabel,
                    filePath: input?.filePath ?? "",
                    diff: DiffBlock(
                        filePath: input?.filePath ?? "",
                        oldString: output(Tools.Write.self)?.originalFile,
                        newString: input?.content ?? ""),
                    errorText: err))

        case .bash:
            let bash = output(Tools.Bash.self)
            return .bash(
                BashChild(
                    id: id,
                    label: label,
                    activeLabel: activeLabel,
                    command: toolUse.input(as: Tools.Bash.self)?.command ?? "",
                    stdout: bash?.stdout,
                    stderr: bash?.stderr,
                    errorText: err))

        case .grep:
            let grep = output(Tools.Grep.self)
            return .grep(
                GrepChild(
                    id: id,
                    label: label,
                    activeLabel: activeLabel,
                    pattern: toolUse.input(as: Tools.Grep.self)?.pattern ?? "",
                    filenames: grep?.filenames ?? [],
                    content: grep?.content,
                    errorText: err))

        case .glob:
            let glob = output(Tools.Glob.self)
            return .glob(
                GlobChild(
                    id: id,
                    label: label,
                    activeLabel: activeLabel,
                    pattern: toolUse.input(as: Tools.Glob.self)?.pattern ?? "",
                    filenames: glob?.filenames ?? [],
                    truncated: glob?.truncated ?? false,
                    errorText: err))

        case .webFetch:
            let fetch = output(Tools.WebFetch.self)
            return .webFetch(
                WebFetchChild(
                    id: id,
                    label: label,
                    activeLabel: activeLabel,
                    url: toolUse.input(as: Tools.WebFetch.self)?.url ?? "",
                    httpStatus: fetch?.code,
                    result: fetch?.result,
                    errorText: err))

        case .webSearch:
            let links = output(Tools.WebSearch.self)?.links ?? []
            return .webSearch(
                WebSearchChild(
                    id: id,
                    label: label,
                    activeLabel: activeLabel,
                    query: toolUse.input(as: Tools.WebSearch.self)?.query ?? "",
                    results: links.map { WebSearchChild.Result(title: $0.title, url: $0.url, snippet: nil) },
                    errorText: err))

        case .askUserQuestion:
            let answers = output(Tools.AskUserQuestion.self)?.answers
            let questions = toolUse.input(as: Tools.AskUserQuestion.self)?.questions ?? []
            return .askUserQuestion(
                AskUserQuestionChild(
                    id: id,
                    label: label,
                    activeLabel: activeLabel,
                    items: questions.map {
                        AskUserQuestionChild.Item(question: $0.question, answer: answers?[$0.question])
                    },
                    errorText: err))

        case .agent:
            // A background agent's report arrives later as a task
            // notification, not in this result.
            var report: String?
            if case .completed(let run)? = output(Tools.Agent.self), !run.text.isEmpty {
                report = run.text
            }
            return .agent(
                AgentChild(
                    id: id,
                    label: label,
                    activeLabel: activeLabel,
                    description: toolUse.input(as: Tools.Agent.self)?.description ?? "Agent",
                    progress: [],
                    output: report,
                    errorText: err))

        case .other:
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
    private static func errorText(from result: UserMessage?) -> String? {
        guard result?.toolResult?.isError == true,
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

    /// Concatenate the text of a tool result. Returns `nil` when the result
    /// is missing or carries no text (image-only / unknown shapes), so callers
    /// can distinguish "not landed yet" from "landed empty".
    private static func extractText(from result: UserMessage?) -> String? {
        let parts = (result?.toolResult?.content ?? []).compactMap { block -> String? in
            guard let text = block.text, !text.isEmpty else { return nil }
            return text
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
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
