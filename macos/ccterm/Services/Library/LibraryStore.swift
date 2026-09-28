import AgentSDK
import Combine
import Foundation

/// Every transcript in the CLI's session directory (`~/.claude/projects`),
/// as a tree of `LibraryNode`s: project → session → its subagents and
/// workflow runs. The files are the only source; the store scans them off the
/// main actor and rescans when the directory changes.
@MainActor
final class LibraryStore {
    /// Projects, most recently active first; within one, sessions likewise.
    ///
    /// Published only when the tree actually changes: a live session appends
    /// to its file every few seconds, and re-publishing an equal tree would
    /// read downstream as a change. A cold scan publishes as it goes, newest
    /// sessions first, so the top of the list fills before the rest is read.
    @Published private(set) var nodes: [LibraryNode] = []

    private let directory: SessionDirectory
    private let scanner = LibraryScanner()
    private var monitor: DirectoryTreeMonitor?
    private var scanTask: Task<Void, Never>?
    private var needsScan = false
    /// The last complete listing, which a rescan updates where files changed;
    /// `nil` until the first scan finishes, and after `stop()`.
    private var listing: [SessionFile]?
    /// Files changed since the scan in flight took its list.
    private var changedFiles: [URL] = []

    init(directory: SessionDirectory) {
        self.directory = directory
    }

    /// Scans once, then keeps scanning as the directory changes.
    func start() {
        guard monitor == nil else { return }
        let monitor = DirectoryTreeMonitor(directory: directory.url, latency: Self.latency) {
            @Sendable [weak self] events in
            let files = events.map(\.url)
            Task { @MainActor in self?.filesDidChange(files) }
        }
        monitor.start()
        self.monitor = monitor
        setNeedsScan()
    }

    /// Stops watching the directory and abandons a scan in flight.
    func stop() {
        monitor?.stop()
        monitor = nil
        scanTask?.cancel()
        scanTask = nil
        needsScan = false
        listing = nil
        changedFiles = []
    }

    private func filesDidChange(_ files: [URL]) {
        changedFiles += files
        setNeedsScan()
    }

    /// Scans now, or right after the scan in flight — never two at once, and
    /// any number of changes during one scan cost one more.
    private func setNeedsScan() {
        guard scanTask == nil else {
            needsScan = true
            return
        }
        scanTask = Task { [weak self] in
            await self?.scan()
            guard let self, !Task.isCancelled else { return }
            scanTask = nil
            if needsScan {
                needsScan = false
                setNeedsScan()
            }
        }
    }

    /// Lists — again only where files changed, once there is a listing to
    /// update — then reads what changed, in batches that publish as they land.
    private func scan() async {
        let directory = directory
        let scanner = scanner
        let previous = listing
        let changed = changedFiles
        changedFiles = []
        let started = Date()
        let (sessions, touched) = await Task.detached(priority: .utility) {
            guard let previous else { return (directory.sessions(), Set<URL>()) }
            let sessions = directory.sessions(updating: previous, changesAt: changed)
            // A subagent's file changing leaves its session's own date alone.
            let touched = sessions.filter { session in changed.contains(where: session.contains) }.map(\.url)
            return (sessions, Set(touched))
        }.value
        let listed = Date()
        // A rescan reads a file or two: one batch, one tree.
        let size = previous == nil ? Self.batchSize : max(sessions.count, 1)
        var batches = stride(from: 0, to: sessions.count, by: size).map {
            Array(sessions[$0..<min($0 + size, sessions.count)])
        }
        if batches.isEmpty { batches = [[]] }
        var read = 0
        for (index, batch) in batches.enumerated() {
            let isLast = index == batches.count - 1
            let (count, tree) = await Task.detached(priority: .utility) {
                let count = await scanner.read(batch, forcing: touched)
                if isLast { scanner.forget(allBut: sessions) }
                return (count, scanner.tree(of: sessions))
            }.value
            read += count
            guard !Task.isCancelled else { return }
            if tree != nodes { nodes = tree }
        }
        listing = sessions
        appLog(
            .debug, "LibraryStore",
            "scanned \(sessions.count) sessions, read \(read): listing \(Self.seconds(started, listed)), "
                + "total \(Self.seconds(started, Date()))")
    }

    private static func seconds(_ from: Date, _ to: Date) -> String {
        String(format: "%.2fs", to.timeIntervalSince(from))
    }

    /// Sessions read between two publishes on a cold scan: a screenful of
    /// projects arrives with the first.
    private static let batchSize = 256

    /// How long the directory is let to settle before a rescan.
    private static let latency: TimeInterval = 1
}
