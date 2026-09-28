import AgentSDK
import Combine
import Foundation

/// Every transcript someone ran at the CLI's prompt, from the CLI's session
/// directory, as a tree of `LibraryNode`s: project → session → its subagents
/// and workflow runs. Left out: sessions run through `claude -p` or an SDK,
/// those that record no working directory, and those run in a temporary or
/// hidden directory.
///
/// Reads every session once on `start()`, then only the sessions the
/// directory reports changed.
@MainActor
final class LibraryStore {
    /// Projects, most recently active first; within one, sessions likewise.
    ///
    /// Published only when the tree actually changes: a live session appends
    /// to its file every few seconds, and re-publishing an equal tree would
    /// read downstream as a change.
    @Published private(set) var nodes: [LibraryNode] = []

    private let directory: SessionDirectory
    private var task: Task<Void, Never>?
    /// What each shown session read as, by transcript.
    private var entries: [URL: Entry] = [:]

    init(directory: SessionDirectory) {
        self.directory = directory
    }

    /// Reads every session, then keeps up with the directory.
    func start() {
        guard task == nil else { return }
        let directory = directory
        task = Task { [weak self] in
            // Watching starts before the listing, so nothing written between
            // the two is missed.
            let changes = directory.changes()
            let all = await Self.read(directory.sessions())
            self?.update(all)
            for await sessions in changes {
                let read = await Self.read(sessions)
                guard let self else { return }
                update(read)
            }
        }
    }

    /// Stops keeping up; `start()` reads everything again.
    func stop() {
        task?.cancel()
        task = nil
        entries = [:]
    }

    private func update(_ read: [URL: Entry?]) {
        for (url, entry) in read { entries[url] = entry }
        let tree = Self.tree(of: entries.values)
        if tree != nodes { nodes = tree }
    }

    // MARK: - Queries

    /// The library's nodes from a project down to the transcript at `url`, or
    /// none if it isn't in the library: `last` is the transcript's node, `first`
    /// its project — its folder in the sidebar.
    func path(toTranscriptAt url: URL) -> [LibraryNode] {
        func path(from node: LibraryNode) -> [LibraryNode]? {
            if node.transcriptURL == url { return [node] }
            for child in node.children {
                if let rest = path(from: child) { return [node] + rest }
            }
            return nil
        }
        return nodes.lazy.compactMap(path(from:)).first ?? []
    }

    /// The git branch of the session whose transcript is at `url`, read when
    /// asked and followed until the consumer stops iterating: the live branch
    /// of the directory the session runs in (a worktree's own), found in the
    /// transcript's metadata, or — when that directory is no repository any
    /// more — the branch the transcript last recorded, once. `nil` while HEAD
    /// is detached or when neither is known. Reads nothing on the caller's
    /// thread, and always yields at least once.
    nonisolated func branchUpdates(ofTranscriptAt url: URL) -> AsyncStream<String?> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let metadata = try? SessionMetadata(contentsOf: url)
                guard let root = metadata?.cwd.flatMap(GitUtils.repositoryRoot(containing:)) else {
                    // The CLI records a detached HEAD as "HEAD".
                    continuation.yield(metadata?.gitBranch.flatMap { $0 == "HEAD" ? nil : $0 })
                    continuation.finish()
                    return
                }
                for await branch in GitUtils.currentBranchUpdates(at: root) { continuation.yield(branch) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Reading

    private struct Entry: Sendable {
        let modificationDate: Date
        let project: String
        let node: LibraryNode
    }

    /// Each session's entry, in parallel; `nil` for one that isn't shown or
    /// can't be read.
    @concurrent
    private nonisolated static func read(_ sessions: [SessionFile]) async -> [URL: Entry?] {
        await withTaskGroup(of: (URL, Entry?).self) { group in
            for session in sessions {
                group.addTask { (session.url, entry(for: session)) }
            }
            return await group.reduce(into: [URL: Entry?]()) { $0[$1.0] = .some($1.1) }
        }
    }

    private nonisolated static func entry(for session: SessionFile) -> Entry? {
        guard let metadata = try? SessionMetadata(contentsOf: session.url), metadata.isInteractive,
            let cwd = metadata.cwd, !isScratch(project(ofDirectory: cwd))
        else { return nil }
        let title =
            [metadata.title, metadata.lastPrompt]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? String(localized: "Untitled Session")
        let node = LibraryNode(
            id: session.url.path, kind: .session, title: title, transcriptURL: session.url,
            children: children(of: session))
        return Entry(modificationDate: session.modificationDate, project: project(ofDirectory: cwd), node: node)
    }

    private nonisolated static func children(of session: SessionFile) -> [LibraryNode] {
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

    private nonisolated static func node(_ agent: SubagentFile) -> LibraryNode {
        LibraryNode(
            id: agent.url.path, kind: .agent,
            title: agent.task ?? agent.agentType ?? agent.url.deletingPathExtension().lastPathComponent,
            transcriptURL: agent.url, children: [])
    }

    // MARK: - Tree

    /// Projects in the order of their newest session; sessions newest first.
    private static func tree(of entries: some Sequence<Entry>) -> [LibraryNode] {
        var order: [String] = []
        var members: [String: [LibraryNode]] = [:]
        for entry in entries.sorted(by: { $0.modificationDate > $1.modificationDate }) {
            if members[entry.project] == nil { order.append(entry.project) }
            members[entry.project, default: []].append(entry.node)
        }
        return order.map { path in
            LibraryNode(
                id: path, kind: .project, title: title(ofProject: path), transcriptURL: nil,
                children: members[path] ?? [])
        }
    }

    /// A session run in one of a repository's worktrees
    /// (`<repo>/.claude/worktrees/<name>/…`) belongs to the repository.
    private nonisolated static func project(ofDirectory path: String) -> String {
        guard let range = path.range(of: "/.claude/worktrees/") else { return path }
        return String(path[..<range.lowerBound])
    }

    /// A directory no one keeps a project in: a temporary one, or one inside
    /// a hidden directory (`~/.cache/…`) — where scripts and tools run the
    /// CLI, not people.
    private nonisolated static func isScratch(_ path: String) -> Bool {
        ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"].contains { path.hasPrefix($0) }
            || URL(fileURLWithPath: path).pathComponents.contains { $0.hasPrefix(".") }
    }

    private static func title(ofProject path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }
}
