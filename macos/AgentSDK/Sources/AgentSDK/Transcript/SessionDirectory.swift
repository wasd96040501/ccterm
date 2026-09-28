import CoreServices
import Foundation

/// The directory the CLI keeps session transcripts in (`~/.claude/projects`).
///
/// Lists the sessions on disk and reports which of them change; read a
/// listed file with ``Transcript/init(contentsOf:)`` or
/// ``SessionMetadata/init(contentsOf:)``.
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
        return projects.filter(\.isDirectory).flatMap(Self.sessions(inProject:))
            .sorted { $0.modificationDate > $1.modificationDate }
    }

    /// The sessions whose transcript, or a file they spawned, changed — one
    /// element per burst of changes, from when iteration starts until it
    /// ends. A session whose transcript was deleted is reported too; reading
    /// it fails. When the file system can't say where a change was, every
    /// session is reported.
    public func changes() -> AsyncStream<[SessionFile]> {
        AsyncStream { continuation in
            let watcher = Watcher(directory: self) { continuation.yield($0) }
            continuation.onTermination = { _ in watcher.stop() }
            watcher.start()
        }
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

    /// The sessions changes at `paths` belong to, or `nil` when one of them
    /// can't be placed. `root` is the directory's path with symlinks
    /// resolved, as the file system reports changes (`/private/var/…`).
    /// Anything else under a project — tool results, memory — is no session's.
    fileprivate func sessions(changedAt paths: [String], root: [String]) -> [SessionFile]? {
        var changed: [URL: SessionFile] = [:]
        for path in paths {
            let components = URL(fileURLWithPath: path).pathComponents
            guard components.count >= root.count + 2, Array(components.prefix(root.count)) == root else {
                return nil
            }
            let relative = Array(components.dropFirst(root.count))
            let name: String
            if relative.count == 2, relative[1].hasSuffix(".jsonl") {
                name = relative[1]
            } else if relative.count >= 3, ["subagents", "workflows"].contains(relative[2]) {
                name = relative[1] + ".jsonl"
            } else {
                continue
            }
            let file = url.appendingPathComponent(relative[0], isDirectory: true).appendingPathComponent(name)
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            changed[file] = SessionFile(url: file, modificationDate: date ?? .distantPast)
        }
        return Array(changed.values)
    }
}

extension SessionDirectory {
    /// An FSEvents stream over the directory, reporting sessions.
    private final class Watcher: @unchecked Sendable {
        private let directory: SessionDirectory
        private let report: @Sendable ([SessionFile]) -> Void
        private let queue = DispatchQueue(label: "AgentSDK.SessionDirectory", qos: .utility)
        private var stream: FSEventStreamRef?
        private var root: [String] = []

        init(directory: SessionDirectory, report: @escaping @Sendable ([SessionFile]) -> Void) {
            self.directory = directory
            self.report = report
        }

        func start() {
            queue.sync {
                root = Self.realPath(of: directory.url) ?? directory.url.pathComponents
                var context = FSEventStreamContext()
                context.info = Unmanaged.passUnretained(self).toOpaque()
                let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                guard
                    let stream = FSEventStreamCreate(
                        nil, Self.callback, &context, [directory.url.path] as CFArray,
                        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, UInt32(flags))
                else { return }
                self.stream = stream
                FSEventStreamSetDispatchQueue(stream, queue)
                FSEventStreamStart(stream)
            }
        }

        func stop() {
            queue.sync {
                guard let stream else { return }
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
        }

        /// Runs on `queue`.
        private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
            let unplaced = UInt32(
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                    | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
            let sessions =
                flags.contains { $0 & unplaced != 0 }
                ? nil : directory.sessions(changedAt: paths, root: root)
            let changed = sessions ?? directory.sessions()
            if !changed.isEmpty { report(changed) }
        }

        private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info, let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            let watcher = Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue()
            watcher.handle(paths: paths, flags: Array(UnsafeBufferPointer(start: flags, count: count)))
        }

        /// How long changes are let to settle before they are reported.
        private static let latency: CFTimeInterval = 1

        private static func realPath(of url: URL) -> [String]? {
            guard let resolved = realpath(url.path, nil) else { return nil }
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved)).pathComponents
        }
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
