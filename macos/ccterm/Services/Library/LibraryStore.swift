import Combine
import Foundation

/// Every transcript under the CLI's projects directory (`~/.claude/projects`),
/// as a tree of `LibraryNode`s: project → session → its subagents and
/// workflow runs. The files are the only source; the store scans them off the
/// main actor and rescans when the directory changes.
@MainActor
final class LibraryStore {
    /// Projects, most recently active first.
    ///
    /// Published only when the tree actually changes: a live session appends
    /// to its file every few seconds, and re-publishing an equal tree would
    /// read downstream as a change.
    @Published private(set) var nodes: [LibraryNode] = []

    private let root: URL

    init(root: URL) {
        self.root = root
    }

    /// Scans once, then keeps scanning as the directory changes.
    func start() {}

    /// Stops watching the directory and abandons a scan in flight.
    func stop() {}
}
