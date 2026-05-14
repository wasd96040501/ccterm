import AgentSDK
import Foundation

/// 把 `ToolUse + ToolResultPayload` 转成 `ToolGroupBlock.Child`。
///
/// 与老 `ToolBlockView` 的派发逻辑同构,但产出是 native transcript 的
/// per-kind child struct:每个 child 自带稳定 `id`(StableBlockID 派生
/// 自 toolUseId)+ 显示用 `label` + 渲染时需要的字段。
enum ToolUseToChild {
    /// `toolUseId` 唯一标识本次工具调用,贯穿 child id / fold-state /
    /// highlight scope。`result` 来自 `SingleEntry.toolResults[toolUseId]`。
    static func make(toolUse: ToolUse,
                     toolUseId: String,
                     result: ToolResultPayload?) -> ToolGroupBlock.Child {
        let label = headerLabel(for: toolUse, hasResult: result != nil)
        let id = StableBlockID.derive("tool", toolUseId)
        let resultObject: ToolUseResultObject? = {
            if case .object(let obj) = result?.typed { return obj }
            return nil
        }()

        switch toolUse {
        case .Read(let v):
            return .read(ReadChild(
                id: id,
                label: label,
                filePath: v.input?.filePath ?? ""))

        case .Edit(let v):
            return .fileEdit(FileEditChild(
                id: id,
                label: label,
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
            return .fileEdit(FileEditChild(
                id: id,
                label: label,
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
            return .bash(BashChild(
                id: id,
                label: label,
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
            return .grep(GrepChild(
                id: id,
                label: label,
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
            return .glob(GlobChild(
                id: id,
                label: label,
                pattern: v.input?.pattern ?? "",
                filenames: filenames,
                truncated: truncated))

        case .WebFetch(let v):
            let (httpStatus, body): (Int?, String?) = {
                if case .WebFetch(let obj, _) = resultObject { return (obj.code, obj.result) }
                return (nil, nil)
            }()
            return .webFetch(WebFetchChild(
                id: id,
                label: label,
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
            return .webSearch(WebSearchChild(
                id: id,
                label: label,
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
            return .askUserQuestion(AskUserQuestionChild(
                id: id,
                label: label,
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
            return .agent(AgentChild(
                id: id,
                label: label,
                description: v.input?.description ?? v.input?.name ?? "Agent",
                progress: progress,
                output: output))

        default:
            return .generic(GenericChild(id: id, label: label))
        }
    }

    /// 子项 header 文案。与老 `ToolBlockView.headerTitle` 同样的语义:有
    /// result(已完成)用 completedFragment,否则用 activeFragment。展开
    /// 后的 children 一律以已完成形态展示(group 头由 ToolGroup 自己合成)。
    private static func headerLabel(for toolUse: ToolUse, hasResult: Bool) -> String {
        if hasResult, let s = toolUse.completedFragment { return s }
        if !hasResult, let s = toolUse.activeFragment { return s }
        return toolUse.caseName
    }
}
