import AgentSDK
import Combine
import Foundation

/// Every transcript someone ran at the CLI's prompt, from the CLI's session
/// directory, as a tree of `LibraryNode`s: project → session → its subagents
/// and workflow runs. Left out: sessions run through `claude -p` or an SDK,
/// those that record no working directory, and those run in a temporary or
/// hidden directory.
///
/// Reads every session once on `start()` — given an index, only those written
/// since the last launch — then only the sessions the directory reports
/// changed; reads one transcript, or what it records, when asked. Reads
/// nothing on the main thread.
@MainActor
final class LibraryStore {
    /// Projects, most recently active first; within one, sessions likewise.
    ///
    /// Published only when the tree actually changes: a live session appends
    /// to its file every few seconds, and re-publishing an equal tree would
    /// read downstream as a change.
    @Published private(set) var nodes: [LibraryNode] = []

    private let directory: SessionDirectory
    /// Where the `LibraryIndex` is kept between launches; `nil` keeps none.
    private let indexURL: URL?
    private var task: Task<Void, Never>?
    /// What each shown session read as, by transcript.
    private var entries: [URL: Entry] = [:]

    init(directory: SessionDirectory, indexURL: URL? = nil) {
        self.directory = directory
        self.indexURL = indexURL
    }

    /// Reads every session, then keeps up with the directory.
    func start() {
        guard task == nil else { return }
        let directory = directory
        let indexURL = indexURL
        task = Task { [weak self] in
            // Watching starts before the listing, so nothing written between
            // the two is missed.
            let changes = directory.changes()
            // The tree as soon as the directory is listed: the index answers
            // for every transcript unchanged since it was written.
            let launch = await Self.launch(directory, indexedAt: indexURL)
            self?.update(launch.records)
            // Then the side transcripts the index answered for, as they are on
            // disk: they come and go without their session's transcript
            // changing.
            let current = await Self.relisted(launch.records, of: launch.indexed)
            self?.update(current)
            if let indexURL { await Self.write(current, over: launch.index, to: indexURL) }
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

    private func update(_ read: [SessionFile: Record?]) {
        for (session, record) in read { entries[session.url] = record.flatMap { Self.entry(for: session, $0) } }
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

    /// The transcript at `url`, read off the caller's actor.
    @concurrent
    nonisolated func transcript(at url: URL) async throws -> Transcript {
        try Transcript(contentsOf: url)
    }

    /// What the transcript at `url` records about its session — where it ran,
    /// on which branch — read off the caller's actor; `nil` if it can't be read.
    @concurrent
    nonisolated func metadata(ofTranscriptAt url: URL) async -> SessionMetadata? {
        try? SessionMetadata(contentsOf: url)
    }

    // MARK: - Reading

    private struct Entry: Sendable {
        let modificationDate: Date
        let project: String
        let node: LibraryNode
    }

    private typealias Record = LibraryIndex.Record

    /// Every session in `directory`: what the index at `indexURL` records for
    /// those unchanged since — `indexed` — and what the rest read as. `nil`
    /// for a session that can't be read.
    @concurrent
    private nonisolated static func launch(
        _ directory: SessionDirectory, indexedAt indexURL: URL?
    ) async
        -> (records: [SessionFile: Record?], indexed: [SessionFile], index: LibraryIndex)
    {
        let clock = ContinuousClock()
        let start = clock.now
        let sessions = directory.sessions()
        let index = indexURL.map(LibraryIndex.init(contentsOf:)) ?? LibraryIndex()
        var records: [SessionFile: Record?] = [:]
        var unread: [SessionFile] = []
        for session in sessions {
            if let record = index.record(for: session) { records[session] = record } else { unread.append(session) }
        }
        let indexed = Array(records.keys)
        records.merge(await read(unread)) { $1 }
        appLog(
            .info, "LibraryStore", "listed \(sessions.count) sessions, read \(unread.count), in \(clock.now - start)")
        return (records, indexed, index)
    }

    /// Each session as its files read now, in parallel.
    @concurrent
    private nonisolated static func read(_ sessions: [SessionFile]) async -> [SessionFile: Record?] {
        await map(sessions) { try? record(of: $0) }
    }

    /// `records`, with the side transcripts of `sessions` as they are on disk
    /// now.
    @concurrent
    private nonisolated static func relisted(
        _ records: [SessionFile: Record?], of sessions: [SessionFile]
    ) async
        -> [SessionFile: Record?]
    {
        let clock = ContinuousClock()
        let start = clock.now
        let shown = sessions.filter { records[$0]??.summary != nil }
        var current = records
        current.merge(await map(shown) { session in records[session]??.relisting(children(of: session)) }) { $1 }
        appLog(.info, "LibraryStore", "listed the side transcripts of \(shown.count) sessions in \(clock.now - start)")
        return current
    }

    /// Writes the index of `records` to `url`, unless it is `previous`.
    @concurrent
    private nonisolated static func write(
        _ records: [SessionFile: Record?], over previous: LibraryIndex, to url: URL
    )
        async
    {
        let index = LibraryIndex(records.compactMap { session, record in record.map { (session, $0) } })
        guard index != previous else { return }
        do {
            try index.write(to: url)
        } catch {
            appLog(.warning, "LibraryStore", "index not written: \(error.localizedDescription)")
        }
    }

    /// `transform` of each session, in parallel.
    private nonisolated static func map(
        _ sessions: [SessionFile], _ transform: @escaping @Sendable (SessionFile) -> Record?
    ) async -> [SessionFile: Record?] {
        await withTaskGroup(of: (SessionFile, Record?).self) { group in
            for session in sessions {
                group.addTask { (session, transform(session)) }
            }
            return await group.reduce(into: [SessionFile: Record?]()) { $0[$1.0] = .some($1.1) }
        }
    }

    /// What the session's files read as; throws if its transcript can't be
    /// read.
    private nonisolated static func record(of session: SessionFile) throws -> Record {
        let metadata = try SessionMetadata(contentsOf: session.url)
        guard metadata.isInteractive, let cwd = metadata.cwd, !isScratch(project(ofDirectory: cwd)) else {
            return Record(modificationDate: session.modificationDate, summary: nil)
        }
        let title =
            [metadata.title, metadata.lastPrompt]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return Record(
            modificationDate: session.modificationDate,
            summary: Record.Summary(project: project(ofDirectory: cwd), title: title, children: children(of: session)))
    }

    /// A shown session's entry; `nil` for one that isn't.
    private nonisolated static func entry(for session: SessionFile, _ record: Record) -> Entry? {
        guard let summary = record.summary else { return nil }
        let node = LibraryNode(
            id: session.url.path, kind: .session, title: summary.title ?? String(localized: "Untitled Session"),
            transcriptURL: session.url, children: summary.children)
        return Entry(modificationDate: session.modificationDate, project: summary.project, node: node)
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
