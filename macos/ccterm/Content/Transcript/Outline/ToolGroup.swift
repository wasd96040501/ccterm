import Foundation

/// Tool calls made one after another with nothing said between them — one
/// card. What the model did in a stretch is read as one unit: what kinds of
/// work, how much changed, whether anything failed.
nonisolated struct ToolGroup: Sendable, Equatable {
    var steps: [ToolStep]

    /// `Read 3 files · Edited 2 files · Ran 1 command`, kinds in the order
    /// they first appear.
    var summary: String {
        var order: [ToolStep.Kind] = []
        var counts: [ToolStep.Kind: Int] = [:]
        var editedFiles = Set<String>()
        for step in steps {
            if counts[step.kind] == nil { order.append(step.kind) }
            counts[step.kind, default: 0] += 1
            if step.kind == .edit { editedFiles.insert(step.document?.path ?? step.title) }
        }
        return order.map { kind in
            let count = kind == .edit ? editedFiles.count : counts[kind] ?? 0
            return Self.phrase(kind, count)
        }
        .joined(separator: " · ")
    }

    /// Lines added and removed across every edit, or `nil` when nothing was
    /// edited.
    var lineStat: ToolStep.Stat? {
        var added = 0
        var removed = 0
        var any = false
        for step in steps {
            guard case .lines(let a, let r)? = step.stat else { continue }
            added += a
            removed += r
            any = true
        }
        return any ? .lines(added: added, removed: removed) : nil
    }

    var failures: Int { steps.filter { $0.outcome == .failed }.count }

    private static func phrase(_ kind: ToolStep.Kind, _ n: Int) -> String {
        switch kind {
        case .read: n == 1 ? String(localized: "Read 1 file") : String(localized: "Read \(n) files")
        case .edit: n == 1 ? String(localized: "Edited 1 file") : String(localized: "Edited \(n) files")
        case .command: n == 1 ? String(localized: "Ran 1 command") : String(localized: "Ran \(n) commands")
        case .search: n == 1 ? String(localized: "1 search") : String(localized: "\(n) searches")
        case .web: n == 1 ? String(localized: "1 web request") : String(localized: "\(n) web requests")
        case .agent: n == 1 ? String(localized: "Ran 1 subagent") : String(localized: "Ran \(n) subagents")
        case .other: n == 1 ? String(localized: "Used 1 tool") : String(localized: "Used \(n) tools")
        }
    }
}
