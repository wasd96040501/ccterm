import AgentSDK
import Foundation

/// Turns the sessions a `SessionDirectory` lists into the library tree, off
/// the main actor.
///
/// Keeps what it read per transcript, keyed by modification date, so a rescan
/// re-reads only the files that changed. A session's subagents and workflow
/// runs are re-listed with it — when its own file changes, or when the store
/// forces it because one of the files it spawned did.
///
/// Not thread-safe; `LibraryStore` runs one scan at a time.
nonisolated final class LibraryScanner: @unchecked Sendable {
    private struct Entry: Sendable {
        let modificationDate: Date
        /// The project the session belongs to; `nil` when its file records no
        /// working directory — there is nothing to file it under, so it is
        /// left out.
        let project: String?
        let node: LibraryNode
    }

    private var entries: [URL: Entry] = [:]

    /// Reads, in parallel, the sessions whose files changed since they were
    /// last read, and those in `forced` whatever their date. Answers how many
    /// it read.
    @discardableResult
    func read(_ sessions: [SessionFile], forcing forced: Set<URL> = []) async -> Int {
        let stale = sessions.filter {
            forced.contains($0.url) || entries[$0.url]?.modificationDate != $0.modificationDate
        }
        let read = await withTaskGroup(of: (URL, Entry).self) { group in
            for session in stale {
                group.addTask { (session.url, Self.entry(for: session)) }
            }
            return await group.reduce(into: [URL: Entry]()) { $0[$1.0] = $1.1 }
        }
        entries.merge(read) { $1 }
        return stale.count
    }

    /// Drops what was read for any session not in `sessions`.
    func forget(allBut sessions: [SessionFile]) {
        let kept = Set(sessions.map(\.url))
        entries = entries.filter { kept.contains($0.key) }
    }

    /// The projects `sessions` fall into, in the order their first session
    /// comes in `sessions`; each project's sessions keep that order. Sessions
    /// not read yet are left out.
    func tree(of sessions: [SessionFile]) -> [LibraryNode] {
        var order: [String] = []
        var members: [String: [LibraryNode]] = [:]
        for session in sessions {
            guard let entry = entries[session.url], let project = entry.project else { continue }
            if members[project] == nil { order.append(project) }
            members[project, default: []].append(entry.node)
        }
        return order.map { path in
            LibraryNode(
                id: path, kind: .project, title: Self.title(ofProject: path), transcriptURL: nil,
                children: members[path] ?? [])
        }
    }

    // MARK: - Reading one session

    private static func entry(for session: SessionFile) -> Entry {
        let metadata = try? SessionMetadata(contentsOf: session.url)
        let title =
            [metadata?.title, metadata?.lastPrompt]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? String(localized: "Untitled Session")
        let node = LibraryNode(
            id: session.url.path, kind: .session, title: title, transcriptURL: session.url,
            children: children(of: session))
        return Entry(
            modificationDate: session.modificationDate, project: metadata?.cwd.map(project(ofDirectory:)),
            node: node)
    }

    private static func children(of session: SessionFile) -> [LibraryNode] {
        var children: [LibraryNode] = []
        let subagents = session.subagents()
        if !subagents.isEmpty {
            children.append(
                LibraryNode(
                    id: session.url.path + "/subagents", kind: .subagents, title: String(localized: "Subagents"),
                    transcriptURL: nil, children: subagents.map(node)))
        }
        for run in session.workflows() {
            children.append(
                LibraryNode(
                    id: session.url.path + "/" + run.id, kind: .workflow, title: run.name ?? run.id,
                    transcriptURL: nil, children: run.agents.map(node)))
        }
        return children
    }

    private static func node(_ agent: SubagentFile) -> LibraryNode {
        LibraryNode(
            id: agent.url.path, kind: .agent,
            title: agent.task ?? agent.agentType ?? agent.url.deletingPathExtension().lastPathComponent,
            transcriptURL: agent.url, children: [])
    }

    // MARK: - Projects

    /// A session run in one of a repository's worktrees
    /// (`<repo>/.claude/worktrees/<name>/…`) belongs to the repository.
    private static func project(ofDirectory path: String) -> String {
        guard let range = path.range(of: "/.claude/worktrees/") else { return path }
        return String(path[..<range.lowerBound])
    }

    private static func title(ofProject path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }
}
