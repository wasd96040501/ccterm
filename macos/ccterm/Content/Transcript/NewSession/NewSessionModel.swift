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
        /// Whether it is the draft's folder (the menu checks it).
        var isChosen = false
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
    /// Request · #N* item for a typed `#N` — is the popover's
    /// (`BranchPickerModel`).
    struct BranchList: Equatable, Sendable {
        var local: [BranchItem]
        var remote: [BranchItem]
        /// The pull request the draft chose, so the typed `#N` item is
        /// marked.
        var chosenPullRequest: Int?

        init(local: [BranchItem], remote: [BranchItem], chosenPullRequest: Int? = nil) {
            self.local = local
            self.remote = remote
            self.chosenPullRequest = chosenPullRequest
        }
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

    /// How many recent folders the menu lists.
    static let recentLimit = 8

    init(draft: NewSessionDraft, repository: Repository, recentFolders: [URL]) {
        let folder = draft.folder
        folderTitle = folder.map(Self.title(of:)) ?? String(localized: "Choose Folder…")
        folderPath = folder.map { ($0.path as NSString).abbreviatingWithTildeInPath }
        self.recentFolders = recentFolders.prefix(Self.recentLimit).map {
            Folder(url: $0, title: Self.title(of: $0), isChosen: $0 == folder)
        }
        canSend = folder != nil

        switch repository {
        case .loading:
            branchRow = .loading
            explanation = nil
        case .notARepository:
            branchRow = .notARepository(String(localized: "Not a git repository"))
            explanation = nil
        case .repository(let state):
            let shown = Self.shownBranch(of: draft, in: state)
            branchRow = .repository(
                branchTitle: shown,
                usesWorktree: draft.usesWorktree,
                branches: Self.list(of: draft, in: state))
            explanation = Self.explanation(of: draft, shown: shown, in: state)
        }
    }

    // MARK: - Words

    private static func title(of folder: URL) -> String {
        folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent
    }

    /// The branch pop-up's title: what the draft chose, else the checked-out
    /// branch (or *Detached HEAD*), or `#N`.
    private static func shownBranch(of draft: NewSessionDraft, in repository: RepositoryState) -> String {
        switch draft.branch {
        case .named(let name): return name
        case .pullRequest(let number): return "#\(number)"
        case nil: return repository.branch ?? String(localized: "Detached HEAD")
        }
    }

    private static func explanation(
        of draft: NewSessionDraft, shown: String, in repository: RepositoryState
    ) -> String? {
        if case .pullRequest(let number) = draft.branch {
            return String(localized: "Pull request #\(number), in a new worktree")
        }
        if draft.usesWorktree {
            let base = draft.branch == nil ? (repository.branch ?? "HEAD") : shown
            return String(localized: "A new branch from \(base), in a new worktree")
        }
        if draft.branch != nil, shown != repository.branch {
            return String(localized: "Switches to \(shown) when you send")
        }
        return nil
    }

    private static func list(of draft: NewSessionDraft, in repository: RepositoryState) -> BranchList {
        let chosen: String? = {
            switch draft.branch {
            case .named(let name): return name
            case nil: return repository.branch
            case .pullRequest: return nil
            }
        }()
        let inPlace = !draft.usesWorktree

        func item(_ name: String) -> BranchItem {
            let refusal = inPlace ? BranchRules.refusal(of: name, in: repository) : nil
            let subtitle: String? =
                switch refusal {
                case .checkedOutElsewhere: String(localized: "Checked out in another worktree")
                case .uncommittedChanges: String(localized: "Uncommitted changes here — use a worktree")
                case nil: name == repository.branch ? String(localized: "Checked out here") : nil
                }
            return BranchItem(name: name, subtitle: subtitle, isEnabled: refusal == nil, isChosen: name == chosen)
        }

        let local = Set(repository.localBranches)
        let remote = repository.remoteBranches.filter { name in
            // A remote branch with a local twin is listed once, as the local one.
            guard let slash = name.firstIndex(of: "/") else { return true }
            return !local.contains(String(name[name.index(after: slash)...]))
        }
        var pullRequest: Int?
        if case .pullRequest(let number) = draft.branch { pullRequest = number }
        return BranchList(
            local: repository.localBranches.map(item), remote: remote.map(item), chosenPullRequest: pullRequest)
    }
}
