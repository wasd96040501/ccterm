import Foundation

/// What the New view shows, worded (design 08 *The New view*): the folder
/// title and its path, the branch row or *Not a git repository*, the line
/// that says what Send will do, the folder menu and the branch list. Pure —
/// built from the draft, the folder's repository and the recent projects;
/// tested without AppKit.
nonisolated struct NewSessionModel: Equatable, Sendable {
    /// The folder pop-up's title (the folder's name), or *Choose Folder…*.
    var folderTitle: String
    /// The path under it, `~` for home; `nil` without a folder.
    var folderPath: String?
    /// The folder menu's *Recent*: the sidebar's projects, eight at most.
    var recentFolders: [Folder]
    var branchRow: BranchRow
    /// What the choices add up to — *Switches to fix-gutter-overflow when you
    /// send*, *A new branch from main, in a new worktree*, *Pull request #327,
    /// in a new worktree* — or `nil` (the line keeps its height).
    var explanation: String?
    /// Whether Send can launch (a folder is known).
    var canSend: Bool

    struct Folder: Equatable, Sendable {
        var url: URL
        var title: String
    }

    /// The row under the path.
    enum BranchRow: Equatable, Sendable {
        /// A git folder: the branch pop-up's title and the Worktree toggle.
        case repository(branchTitle: String, usesWorktree: Bool, branches: BranchList)
        /// *Not a git repository*, at the same height.
        case notARepository(String)
        /// The repository is still being read.
        case loading
    }

    /// The branch popover's list (design 08: *Local* and *Remote*, a remote
    /// branch with a local twin listed once). Filtering — and the *Pull
    /// Request · #N* item for a typed `#N` — is the popover's.
    struct BranchList: Equatable, Sendable {
        var local: [BranchItem]
        var remote: [BranchItem]
    }

    struct BranchItem: Equatable, Sendable {
        var name: String
        /// *Checked out here*; or why it can't be had in place, greyed:
        /// *Checked out in another worktree*, *Uncommitted changes here — use
        /// a worktree*.
        var subtitle: String?
        var isEnabled: Bool
        var isChosen: Bool
    }

    /// What is known of the draft's folder's repository.
    enum Repository: Equatable, Sendable {
        case loading
        case notARepository
        case repository(RepositoryState)
    }

    init(draft: NewSessionDraft, repository: Repository, recentFolders: [URL]) {
        // TODO(fill D): word every part; NewSessionModelTests.
        folderTitle = draft.folder?.lastPathComponent ?? String(localized: "Choose Folder…")
        folderPath = draft.folder.map { ($0.path as NSString).abbreviatingWithTildeInPath }
        self.recentFolders = recentFolders.prefix(8).map { Folder(url: $0, title: $0.lastPathComponent) }
        branchRow = .loading
        explanation = nil
        canSend = draft.folder != nil
    }
}
