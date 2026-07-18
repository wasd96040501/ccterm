import AgentSDK
import Foundation

/// Human-facing tool labels for the outline transcript, rewritten (not
/// imported) from the Session-domain `ToolUse` fragment / aggregation
/// extensions the SPEC forbids depending on (§3). The English source
/// strings are kept **identical** to those in `MessageEntry.swift` so
/// they resolve against the existing `Localizable.xcstrings` entries —
/// no new translation keys are introduced.
///
/// Two consumers:
/// - A single tool's header title uses `completedFragment` (past tense,
///   e.g. "Read foo.swift") — history is always completed.
/// - A group header aggregates its run of tools into a count phrase
///   (e.g. "Read 3 files · Searched 1 pattern") via `groupTitle`.
enum TranscriptToolNarration {

    // MARK: - Group header

    /// Aggregate a run of tool_uses into the group header title. A single
    /// tool folds to its own completed fragment; multiple tools produce
    /// the first-occurrence-ordered, count-suffixed phrase (mirrors the
    /// Session-domain `GroupEntry.completedTitle`).
    static func groupTitle(for tools: [ToolUse]) -> String {
        if tools.count == 1 {
            return completedFragment(tools[0]) ?? tools[0].caseName
        }
        var order: [GroupableKind] = []
        var counts: [GroupableKind: Int] = [:]
        for tool in tools {
            let kind = groupableKind(tool)
            if counts[kind] == nil { order.append(kind) }
            counts[kind, default: 0] += 1
        }
        return
            order
            .compactMap { kind in counts[kind].map { kind.completedCountPhrase($0) } }
            .joined(separator: " · ")
    }

    /// Per-tool header title (past tense). Falls back to the raw case
    /// name (an identifier, not localized) for tools without a tailored
    /// phrase — matching the old `ToolUseToChild` label policy.
    static func toolHeaderTitle(_ tool: ToolUse) -> String {
        completedFragment(tool) ?? tool.caseName
    }

    // MARK: - Fragments (past / progressive)

    static func completedFragment(_ tool: ToolUse) -> String? {
        switch tool {
        case .Read(let v): return String(localized: "Read \(readTarget(v))")
        case .Edit(let v): return String(localized: "Edited \(editTarget(v))")
        case .Write(let v): return String(localized: "Wrote \(writeTarget(v))")
        case .Grep(let v): return String(localized: "Searched \"\(grepTarget(v))\"")
        case .Glob(let v): return String(localized: "Globbed \"\(globTarget(v))\"")
        case .Bash(let v): return String(localized: "Ran \(bashTarget(v))")
        case .WebFetch(let v): return String(localized: "Fetched \(webFetchTarget(v))")
        case .WebSearch(let v): return String(localized: "Searched \"\(webSearchTarget(v))\"")
        case .Agent(let v): return String(localized: "Agent: \(agentTarget(v))")
        case .AskUserQuestion(let v): return String(localized: "Asked: \(askTarget(v))")
        default: return nil
        }
    }

    static func activeFragment(_ tool: ToolUse) -> String? {
        switch tool {
        case .Read(let v): return String(localized: "Reading \(readTarget(v))")
        case .Edit(let v): return String(localized: "Editing \(editTarget(v))")
        case .Write(let v): return String(localized: "Writing \(writeTarget(v))")
        case .Grep(let v): return String(localized: "Searching \"\(grepTarget(v))\"")
        case .Glob(let v): return String(localized: "Globbing \"\(globTarget(v))\"")
        case .Bash(let v): return String(localized: "Running \(bashTarget(v))")
        case .WebFetch(let v): return String(localized: "Fetching \(webFetchTarget(v))")
        case .WebSearch(let v): return String(localized: "Searching \"\(webSearchTarget(v))\"")
        case .Agent(let v): return String(localized: "Running agent: \(agentTarget(v))")
        case .AskUserQuestion(let v): return String(localized: "Asking: \(askTarget(v))")
        default: return nil
        }
    }

    // MARK: - Grouping kind

    /// Every tool participates in grouping; kinds outside the tailored
    /// set fall through to `.other`.
    enum GroupableKind {
        case read, edit, write, grep, glob, bash
        case webFetch, webSearch, agent, askUserQuestion, other

        func completedCountPhrase(_ count: Int) -> String {
            switch self {
            case .read: return String(localized: "Read \(count) files")
            case .edit: return String(localized: "Edited \(count) files")
            case .write: return String(localized: "Wrote \(count) files")
            case .grep: return String(localized: "Searched \(count) patterns")
            case .glob: return String(localized: "Globbed \(count) patterns")
            case .bash: return String(localized: "Ran \(count) commands")
            case .webFetch: return String(localized: "Fetched \(count) URLs")
            case .webSearch: return String(localized: "Searched \(count) queries")
            case .agent: return String(localized: "Ran \(count) agents")
            case .askUserQuestion: return String(localized: "Asked \(count) questions")
            case .other: return String(localized: "Used \(count) tools")
            }
        }
    }

    static func groupableKind(_ tool: ToolUse) -> GroupableKind {
        switch tool {
        case .Read: return .read
        case .Edit: return .edit
        case .Write: return .write
        case .Grep: return .grep
        case .Glob: return .glob
        case .Bash: return .bash
        case .WebFetch: return .webFetch
        case .WebSearch: return .webSearch
        case .Agent: return .agent
        case .AskUserQuestion: return .askUserQuestion
        default: return .other
        }
    }

    // MARK: - Fragment targets

    private static func readTarget(_ v: ToolUseRead) -> String {
        basename(v.input?.filePath) ?? String(localized: "file")
    }
    private static func editTarget(_ v: ToolUseEdit) -> String {
        basename(v.input?.filePath) ?? String(localized: "file")
    }
    private static func writeTarget(_ v: ToolUseWrite) -> String {
        basename(v.input?.filePath) ?? String(localized: "file")
    }
    private static func grepTarget(_ v: ToolUseGrep) -> String { v.input?.pattern ?? "" }
    private static func globTarget(_ v: ToolUseGlob) -> String { v.input?.pattern ?? "" }
    private static func bashTarget(_ v: ToolUseBash) -> String {
        v.input?.description
            ?? v.input?.command.map { String($0.prefix(40)) }
            ?? ""
    }
    private static func webFetchTarget(_ v: ToolUseWebFetch) -> String { v.input?.url ?? "" }
    private static func webSearchTarget(_ v: ToolUseWebSearch) -> String {
        v.input?.query ?? v.input?.searchQuery ?? ""
    }
    private static func agentTarget(_ v: Agent) -> String {
        v.input?.description ?? v.input?.name ?? ""
    }
    private static func askTarget(_ v: ToolUseAskUserQuestion) -> String {
        v.input?.questions?.first?.question ?? ""
    }

    private static func basename(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return (path as NSString).lastPathComponent
    }
}
