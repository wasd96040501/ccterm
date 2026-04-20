import Foundation
import AgentSDK

// MARK: - Entry

/// Timeline entry. Either a plain single message or a group of adjacent
/// same-class tool_use assistant messages.
///
/// Invariant: `.group` never nests — `GroupEntry.items` contains raw
/// `SingleEntry`s.
enum MessageEntry: Identifiable {
    case single(SingleEntry)
    case group(GroupEntry)

    var id: UUID {
        switch self {
        case .single(let e): return e.id
        case .group(let g): return g.id
        }
    }

    /// Flatten to `[SingleEntry]`. `.single` yields one; `.group` yields `items`.
    /// Use at call sites that need to walk actual assistant/user payloads.
    var singles: [SingleEntry] {
        switch self {
        case .single(let e): return [e]
        case .group(let g): return g.items
        }
    }

    /// Convenience forwarder to the inner `.single` payload. `nil` for `.group`.
    var message: Message2? {
        if case .single(let e) = self { return e.message }
        return nil
    }

    /// Convenience forwarder to the inner `.single` payload. Getter returns `nil`
    /// for `.group`; setter is a no-op on `.group`.
    var delivery: DeliveryState? {
        get {
            if case .single(let e) = self { return e.delivery }
            return nil
        }
        set {
            guard case .single(var e) = self else { return }
            e.delivery = newValue
            self = .single(e)
        }
    }
}

// MARK: - SingleEntry

struct SingleEntry: Identifiable {
    let id: UUID
    let message: Message2
    var delivery: DeliveryState?
    var toolResults: [String: ToolResultPayload]
}

/// Merged view of a tool_use's result: the raw tool_result block (text +
/// isError) plus the user message's typed `tool_use_result` projection.
/// Typed-aware blocks (Grep, WebSearch, WebFetch, Bash, etc.) read from
/// `typed`; generic / text-only blocks can fall back to `item.content`.
struct ToolResultPayload {
    let item: ItemToolResult
    let typed: ToolUseResult?

    var toolUseId: String? { item.toolUseId }
    var isError: Bool? { item.isError }
}

extension SingleEntry {
    /// All `toolUse` blocks inside an assistant single, in order. Empty for
    /// user / non-assistant / non-tool_use messages.
    var toolUses: [ToolUse] {
        guard case .assistant(let a) = message,
              let blocks = a.message?.content else { return [] }
        return blocks.compactMap { block in
            if case .toolUse(let t) = block { return t }
            return nil
        }
    }

    /// Whether this assistant single originated the given tool_use id.
    func ownsToolUse(_ id: String) -> Bool {
        toolUses.contains { $0.id == id }
    }
}

// MARK: - GroupEntry

struct GroupEntry: Identifiable {
    let id: UUID
    var items: [SingleEntry]
}

extension GroupEntry {
    /// Group title.
    /// - `isActive == true` (the group is still `messages.last`): show the
    ///   progressive fragment of the **last** item (e.g. `Reading foo.swift`).
    /// - `isActive == false`: summarize all items by verb count, first-occurrence
    ///   order, joined by ` · ` (e.g. `Read 3 files · Searched 1 pattern`).
    func title(isActive: Bool) -> String {
        isActive ? activeTitle : completedTitle
    }

    var activeTitle: String {
        guard let last = items.last,
              let tool = last.toolUses.first else { return "" }
        return tool.activeFragment ?? ""
    }

    var completedTitle: String {
        var order: [GroupableToolName] = []
        var counts: [GroupableToolName: Int] = [:]
        for item in items {
            for tool in item.toolUses {
                guard let kind = tool.groupableKind else { continue }
                if counts[kind] == nil { order.append(kind) }
                counts[kind, default: 0] += 1
            }
        }
        return order.compactMap { kind in
            counts[kind].map { kind.completedCountPhrase($0) }
        }
        .joined(separator: " · ")
    }
}

// MARK: - DeliveryState

/// User entry 生命周期。
///
/// - `queued`：本地已 append，尚未收到 CLI 的 user echo（可能 CLI 还没起、还在 bootstrap、
///   或 CLI 忙着处理前面的 turn，消息还在 CLI 侧排队）。
/// - `confirmed`：CLI 已回显同 uuid 的 user 消息，turn 已真正开始处理。
/// - `failed`：进程退出等不可恢复错误，UI 可提示用户。
///
/// 非 user entry 的 `delivery` 恒为 nil。
enum DeliveryState: Equatable {
    case queued
    case confirmed
    case failed(reason: String)
}

// MARK: - GroupableToolName

/// Tools eligible for grouping. Derived from the typed `ToolUse` surface; any
/// tool outside this set short-circuits a `.group` and starts a new `.single`.
enum GroupableToolName {
    case read
    case edit
    case write
    case grep
    case glob
    case bash

    /// Verb+noun phrase for the completed summary title. Plural form selected
    /// via xcstrings `%lld` variation.
    func completedCountPhrase(_ count: Int) -> String {
        switch self {
        case .read:  return String(localized: "Read \(count) files")
        case .edit:  return String(localized: "Edited \(count) files")
        case .write: return String(localized: "Wrote \(count) files")
        case .grep:  return String(localized: "Searched \(count) patterns")
        case .glob:  return String(localized: "Globbed \(count) patterns")
        case .bash:  return String(localized: "Ran \(count) commands")
        }
    }
}

// MARK: - ToolUse classification / fragments

extension ToolUse {
    /// Non-nil iff this tool belongs to the groupable whitelist.
    var groupableKind: GroupableToolName? {
        switch self {
        case .Read:  return .read
        case .Edit:  return .edit
        case .Write: return .write
        case .Grep:  return .grep
        case .Glob:  return .glob
        case .Bash:  return .bash
        default:     return nil
        }
    }

    /// Progressive / present-continuous phrase (e.g. `Reading foo.swift`).
    /// Consumed by both group titles and standalone ToolBlock headers while
    /// the tool is running. `nil` only for tools where a generic fallback to
    /// `caseName` reads better.
    var activeFragment: String? {
        switch self {
        case .Read(let v):
            return String(localized: "Reading \(readTarget(v))")
        case .Edit(let v):
            return String(localized: "Editing \(editTarget(v))")
        case .Write(let v):
            return String(localized: "Writing \(writeTarget(v))")
        case .Grep(let v):
            return String(localized: "Searching \"\(grepTarget(v))\"")
        case .Glob(let v):
            return String(localized: "Globbing \"\(globTarget(v))\"")
        case .Bash(let v):
            return String(localized: "Running: \(bashTarget(v))")
        case .WebFetch(let v):
            return String(localized: "Fetching \(webFetchTarget(v))")
        case .WebSearch(let v):
            return String(localized: "Searching \"\(webSearchTarget(v))\"")
        case .Agent(let v):
            return String(localized: "Running agent: \(agentTarget(v))")
        case .AskUserQuestion(let v):
            return String(localized: "Asking: \(askTarget(v))")
        default:
            return nil
        }
    }

    /// Past-tense counterpart of ``activeFragment`` (e.g. `Read foo.swift`).
    /// Used for standalone ToolBlock headers once the tool finishes. Group
    /// titles have their own aggregated form (`Read 3 files · …`) and do not
    /// go through this.
    var completedFragment: String? {
        switch self {
        case .Read(let v):
            return String(localized: "Read \(readTarget(v))")
        case .Edit(let v):
            return String(localized: "Edited \(editTarget(v))")
        case .Write(let v):
            return String(localized: "Wrote \(writeTarget(v))")
        case .Grep(let v):
            return String(localized: "Searched \"\(grepTarget(v))\"")
        case .Glob(let v):
            return String(localized: "Globbed \"\(globTarget(v))\"")
        case .Bash(let v):
            return String(localized: "Ran: \(bashTarget(v))")
        case .WebFetch(let v):
            return String(localized: "Fetched \(webFetchTarget(v))")
        case .WebSearch(let v):
            return String(localized: "Searched \"\(webSearchTarget(v))\"")
        case .Agent(let v):
            return String(localized: "Agent: \(agentTarget(v))")
        case .AskUserQuestion(let v):
            return String(localized: "Asked: \(askTarget(v))")
        default:
            return nil
        }
    }
}

// MARK: - Fragment targets

private func readTarget(_ v: ToolUseRead) -> String {
    basename(v.input?.filePath) ?? String(localized: "file")
}

private func editTarget(_ v: ToolUseEdit) -> String {
    basename(v.input?.filePath) ?? String(localized: "file")
}

private func writeTarget(_ v: ToolUseWrite) -> String {
    basename(v.input?.filePath) ?? String(localized: "file")
}

private func grepTarget(_ v: ToolUseGrep) -> String {
    v.input?.pattern ?? ""
}

private func globTarget(_ v: ToolUseGlob) -> String {
    v.input?.pattern ?? ""
}

private func bashTarget(_ v: ToolUseBash) -> String {
    v.input?.description
        ?? v.input?.command.map { String($0.prefix(40)) }
        ?? ""
}

private func webFetchTarget(_ v: ToolUseWebFetch) -> String {
    v.input?.url ?? ""
}

private func webSearchTarget(_ v: ToolUseWebSearch) -> String {
    v.input?.query ?? v.input?.searchQuery ?? ""
}

private func agentTarget(_ v: Agent) -> String {
    v.input?.description ?? v.input?.name ?? ""
}

private func askTarget(_ v: ToolUseAskUserQuestion) -> String {
    v.input?.questions?.first?.question ?? ""
}

private func basename(_ path: String?) -> String? {
    guard let path, !path.isEmpty else { return nil }
    return (path as NSString).lastPathComponent
}
