import AgentSDK
import SwiftUI

/// Dispatches a ``ToolUse`` (and its optional result) to the right block
/// component. This is the only place that knows about SDK types — specific
/// blocks accept plain Swift values and stay trivially previewable.
struct ToolBlockView: View {
    let toolUse: ToolUse
    let result: ToolUseResult?
    let isError: Bool
    let errorText: String?

    var body: some View {
        switch toolUse {
        case .Bash(let t):
            bashBlock(t)
        case .Edit(let t):
            editBlock(t)
        case .Write(let t):
            writeBlock(t)
        case .Read(let t):
            readBlock(t)
        case .Grep(let t):
            grepBlock(t)
        case .Glob(let t):
            globBlock(t)
        case .WebFetch(let t):
            webFetchBlock(t)
        case .WebSearch(let t):
            webSearchBlock(t)
        case .Agent(let t):
            agentBlock(t)
        case .Task(let t):
            taskBlock(t)
        case .AskUserQuestion(let t):
            askUserQuestionBlock(t)
        case .Skill,
             .CronCreate, .SendMessage,
             .EnterPlanMode, .EnterWorktree, .ExitPlanMode, .ExitWorktree,
             .TaskCreate, .TaskOutput, .TaskStop, .TaskUpdate,
             .TeamCreate, .TodoWrite, .ToolSearch,
             .unknown:
            GenericToolBlock(name: headerTitle, status: status())
        }
    }

    // MARK: - Status

    private func status() -> ToolBlockStatus {
        if isError { return .error(errorText ?? "tool execution failed") }
        if result == nil { return .running }
        return .idle
    }

    // MARK: - Header title

    /// Single source of truth for header text across all tool blocks.
    /// Running → `activeFragment`; idle / error → `completedFragment`.
    /// Fallback to `caseName` for tools without tailored phrasing.
    private var headerTitle: String {
        let useActive: Bool
        switch status() {
        case .running: useActive = true
        case .idle, .error: useActive = false
        }
        if useActive, let frag = toolUse.activeFragment { return frag }
        if !useActive, let frag = toolUse.completedFragment { return frag }
        return toolUse.caseName
    }

    // MARK: - Blocks

    private func bashBlock(_ t: ToolUseBash) -> some View {
        let obj = bashResult()
        return BashBlock(
            title: headerTitle,
            command: t.input?.command ?? "",
            stdout: obj?.stdout,
            stderr: obj?.stderr,
            status: status())
    }

    private func editBlock(_ t: ToolUseEdit) -> some View {
        let input = t.input
        return FileEditBlock(
            title: headerTitle,
            filePath: input?.filePath ?? "",
            oldString: input?.oldString ?? "",
            newString: input?.newString ?? "",
            status: status())
    }

    private func writeBlock(_ t: ToolUseWrite) -> some View {
        let obj = writeResultObject()
        return FileWriteBlock(
            title: headerTitle,
            filePath: t.input?.filePath ?? "",
            content: t.input?.content ?? "",
            originalContent: obj?.originalFile,
            status: status())
    }

    private func readBlock(_ t: ToolUseRead) -> some View {
        FileReadBlock(
            title: headerTitle,
            filePath: t.input?.filePath ?? "",
            status: status())
    }

    private func grepBlock(_ t: ToolUseGrep) -> some View {
        let obj = grepResult()
        return GrepBlock(
            title: headerTitle,
            pattern: t.input?.pattern ?? "",
            filenames: obj?.filenames ?? [],
            content: obj?.content,
            numFiles: obj?.numFiles,
            numMatches: obj?.numMatches,
            status: status())
    }

    private func globBlock(_ t: ToolUseGlob) -> some View {
        let obj = globResult()
        return GlobBlock(
            title: headerTitle,
            pattern: t.input?.pattern ?? "",
            filenames: obj?.filenames ?? [],
            numFiles: obj?.numFiles,
            truncated: obj?.truncated ?? false,
            status: status())
    }

    private func webFetchBlock(_ t: ToolUseWebFetch) -> some View {
        let obj = webFetchResult()
        return WebFetchBlock(
            title: headerTitle,
            url: t.input?.url ?? "",
            httpStatus: obj?.code,
            result: obj?.result,
            status: status())
    }

    private func webSearchBlock(_ t: ToolUseWebSearch) -> some View {
        let obj = webSearchResult()
        return WebSearchBlock(
            title: headerTitle,
            query: t.input?.query ?? t.input?.searchQuery ?? "",
            results: webSearchResults(from: obj),
            status: status())
    }

    private func agentBlock(_ t: Agent) -> some View {
        let obj = taskResult()
        return AgentBlock(
            title: headerTitle,
            description: t.input?.description ?? t.input?.name ?? "Agent",
            progress: agentProgress(from: obj),
            outputText: agentOutputText(from: obj),
            agentState: obj?.status,
            toolUseCount: obj?.totalToolUseCount,
            status: status())
    }

    private func taskBlock(_ t: ToolUseTask) -> some View {
        GenericToolBlock(
            name: headerTitle,
            status: status())
    }

    private func askUserQuestionBlock(_ t: ToolUseAskUserQuestion) -> some View {
        let obj = askUserQuestionResult()
        let items = (t.input?.questions ?? []).map { q in
            AskUserQuestionBlock.QAItem(
                question: q.question ?? "",
                answer: obj?.answers?[q.question ?? ""])
        }
        return AskUserQuestionBlock(title: headerTitle, items: items, status: status())
    }

    // MARK: - Result extraction

    private func resultObject() -> ToolUseResultObject? {
        guard case .object(let obj) = result else { return nil }
        return obj
    }

    private func bashResult() -> ObjectBash? {
        if case .Bash(let obj, _) = resultObject() { return obj }
        return nil
    }

    private func writeResultObject() -> ObjectWrite? {
        // Not all result enums expose ObjectWrite — if they do, extract it.
        if case .Write(let obj, _) = resultObject() { return obj }
        return nil
    }

    private func grepResult() -> ObjectGrep? {
        if case .Grep(let obj, _) = resultObject() { return obj }
        return nil
    }

    private func globResult() -> ObjectGlob? {
        if case .Glob(let obj, _) = resultObject() { return obj }
        return nil
    }

    private func webFetchResult() -> ObjectWebFetch? {
        if case .WebFetch(let obj, _) = resultObject() { return obj }
        return nil
    }

    private func webSearchResult() -> ObjectWebSearch? {
        if case .WebSearch(let obj, _) = resultObject() { return obj }
        return nil
    }

    private func taskResult() -> ObjectTask? {
        if case .Task(let obj, _) = resultObject() { return obj }
        return nil
    }

    private func askUserQuestionResult() -> ObjectAskUserQuestion? {
        if case .AskUserQuestion(let obj, _) = resultObject() { return obj }
        return nil
    }

    // MARK: - Web search results mapping

    private func webSearchResults(from obj: ObjectWebSearch?) -> [WebSearchBlock.SearchResult] {
        guard let results = obj?.results else { return [] }
        return results.compactMap { entry -> WebSearchBlock.SearchResult? in
            switch entry {
            case .object(let r):
                return .init(
                    title: r.content?.first?.title ?? r.toolUseId ?? "",
                    url: r.content?.first?.url ?? "",
                    snippet: nil)
            case .string:
                return nil
            case .other:
                return nil
            }
        }
    }

    // MARK: - Agent extractors

    private func agentProgress(from obj: ObjectTask?) -> [AgentBlock.ProgressEntry] {
        guard let contents = obj?.content else { return [] }
        return contents.compactMap { entry in
            guard let text = entry.text, !text.isEmpty else { return nil }
            return AgentBlock.ProgressEntry(text: text)
        }
    }

    private func agentOutputText(from obj: ObjectTask?) -> String? {
        guard let contents = obj?.content else { return nil }
        let texts = contents.compactMap { $0.text }
        return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }

}
