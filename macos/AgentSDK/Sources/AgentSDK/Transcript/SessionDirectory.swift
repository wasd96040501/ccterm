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
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let projects =
            (try? manager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        var sessions: [SessionFile] = []
        for project in projects where project.isDirectory {
            let entries =
                (try? manager.contentsOfDirectory(
                    at: project, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
            for entry in entries where entry.pathExtension == "jsonl" {
                guard let values = try? entry.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
                else { continue }
                sessions.append(
                    SessionFile(url: entry, modificationDate: values.contentModificationDate ?? .distantPast))
            }
        }
        return sessions.sorted { $0.modificationDate > $1.modificationDate }
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
