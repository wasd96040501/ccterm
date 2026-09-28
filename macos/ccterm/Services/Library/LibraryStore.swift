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

    init(directory: SessionDirectory) {
        self.directory = directory
    }

    /// Scans once, then keeps scanning as the directory changes.
    func start() {
        guard monitor == nil else { return }
        let monitor = DirectoryTreeMonitor(directory: directory.url, latency: Self.latency) {
            @Sendable [weak self] _ in
            Task { @MainActor in self?.setNeedsScan() }
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

    private func scan() async {
        let directory = directory
        let scanner = scanner
        let sessions = await Task.detached(priority: .utility) { directory.sessions() }.value
        var batches = stride(from: 0, to: sessions.count, by: Self.batchSize).map {
            Array(sessions[$0..<min($0 + Self.batchSize, sessions.count)])
        }
        if batches.isEmpty { batches = [[]] }
        for (index, batch) in batches.enumerated() {
            let isLast = index == batches.count - 1
            let tree = await Task.detached(priority: .utility) {
                await scanner.read(batch)
                if isLast { scanner.forget(allBut: sessions) }
                return scanner.tree(of: sessions)
            }.value
            guard !Task.isCancelled else { return }
            if tree != nodes { nodes = tree }
        }
    }

    /// Sessions read between two publishes on a cold scan: a screenful of
    /// projects arrives with the first.
    private static let batchSize = 256

    /// How long the directory is let to settle before a rescan.
    private static let latency: TimeInterval = 1
}
