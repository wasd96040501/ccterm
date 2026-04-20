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
    var toolResults: [String: ItemToolResult]
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

    /// Progressive-form fragment (e.g. `Reading foo.swift`). Only populated for
    /// groupable tools.
    var activeFragment: String? {
        switch self {
        case .Read(let v):
            let name = basename(v.input?.filePath) ?? String(localized: "file")
            return String(localized: "Reading \(name)")
        case .Edit(let v):
            let name = basename(v.input?.filePath) ?? String(localized: "file")
            return String(localized: "Editing \(name)")
        case .Write(let v):
            let name = basename(v.input?.filePath) ?? String(localized: "file")
            return String(localized: "Writing \(name)")
        case .Grep(let v):
            let pattern = v.input?.pattern ?? ""
            return String(localized: "Searching \"\(pattern)\"")
        case .Glob(let v):
            let pattern = v.input?.pattern ?? ""
            return String(localized: "Globbing \"\(pattern)\"")
        case .Bash(let v):
            let intent = v.input?.description
                ?? v.input?.command.map { String($0.prefix(40)) }
                ?? ""
            return String(localized: "Running: \(intent)")
        default:
            return nil
        }
    }
}

private func basename(_ path: String?) -> String? {
    guard let path, !path.isEmpty else { return nil }
    return (path as NSString).lastPathComponent
}
