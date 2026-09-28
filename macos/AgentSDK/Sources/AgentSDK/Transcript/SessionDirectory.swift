import Foundation

/// The directory the CLI keeps session transcripts in (`~/.claude/projects`).
///
/// Lists what is on disk and nothing more; read a listed file with
/// ``Transcript/init(contentsOf:)`` or ``SessionMetadata/init(contentsOf:)``.
public struct SessionDirectory: Sendable, Hashable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The directory a CLI launched with `environment` writes to:
    /// `$CLAUDE_CONFIG_DIR/projects`, else `~/.claude/projects`. Pass the
    /// environment the CLI is launched with — an app started from Finder has
    /// launchd's, not the login shell's.
    public init(environment: [String: String]) {
        let config =
            environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        url = config.appendingPathComponent("projects", isDirectory: true)
    }

    /// Every session's main transcript, most recently modified first. A
    /// missing or unreadable directory answers `[]`; unreadable entries are
    /// skipped.
    public func sessions() -> [SessionFile] {
        let projects =
            (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        return projects.filter(\.isDirectory).flatMap(Self.sessions(inProject:)).sorted(by: Self.newestFirst)
    }

    /// What ``sessions()`` answers now, given that it answered `previous`
    /// and every file changed since is in `paths` — but listing again only
    /// where those paths are, which costs a fraction of a full listing. A
    /// path it can't place lists everything.
    public func sessions(updating previous: [SessionFile], changesAt paths: [URL]) -> [SessionFile] {
        guard let root = Self.realPath(of: url) else { return sessions() }
        var projects = Set<String>()
        for path in paths {
            let components = path.pathComponents
            guard components.count > root.count, Array(components.prefix(root.count)) == root else {
                return sessions()
            }
            projects.insert(components[root.count])
        }
        let kept = previous.filter { !projects.contains($0.projectName) }
        let listed = projects.flatMap { Self.sessions(inProject: url.appendingPathComponent($0, isDirectory: true)) }
        return (kept + listed).sorted(by: Self.newestFirst)
    }

    private static func sessions(inProject project: URL) -> [SessionFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: project, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        return entries.compactMap { entry in
            guard entry.pathExtension == "jsonl", let values = try? entry.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true
            else { return nil }
            return SessionFile(url: entry, modificationDate: values.contentModificationDate ?? .distantPast)
        }
    }

    private static func newestFirst(_ a: SessionFile, _ b: SessionFile) -> Bool {
        a.modificationDate > b.modificationDate
    }

    /// The directory's components with symlinks resolved, as the file
    /// system reports changes (`/private/var/…`, not `/var/…`).
    private static func realPath(of url: URL) -> [String]? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved)).pathComponents
    }
}

extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// When the file was created, else last modified: what "chronological"
    /// means for the files a session spawns.
    var creationDate: Date {
        let values = try? resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? .distantPast
    }
}
