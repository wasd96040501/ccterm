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

        switch toolUse {
        case .Read(let v):
            return .read(
                ReadChild(
                    id: id,
                    label: label,
                    activeLabel: activeLabel,
                    filePath: v.input?.filePath ?? ""))

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
                        newString: v.input?.newString ?? "")))

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
                        newString: v.input?.content ?? "")))

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
                    stderr: stderr))

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
                    content: content))

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
                    truncated: truncated))

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
                    result: body))

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
                    results: results))

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
                    items: items))

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
                    output: output))

        default:
            return .generic(
                GenericChild(
                    id: id, label: label, activeLabel: activeLabel))
        }
    }
}
