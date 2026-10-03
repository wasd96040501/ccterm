import Foundation

/// What the New view is shown, worded: the folder pop-up's title and the path
/// under it, the folders its menu lists, the row under the path, and the line
/// that says what Send will do. The app builds it from the draft and the
/// folder's repository; the view draws it as it is.
public struct NewSessionContent: Equatable, Sendable {
    /// The folder pop-up's title (the folder's name), or *Choose Folder…*.
    public var folderTitle: String
    /// The path under it, `~` for home; `nil` without a folder.
    public var folderPath: String?
    /// The folder menu's *Recent*, in the order shown; empty lists none.
    public var recentFolders: [Folder]
    public var branchRow: BranchRow
    /// What the choices add up to, or `nil` (the line keeps its height).
    public var explanation: String?

    public init(
        folderTitle: String, folderPath: String? = nil, recentFolders: [Folder] = [], branchRow: BranchRow,
        explanation: String? = nil
    ) {
        self.folderTitle = folderTitle
        self.folderPath = folderPath
        self.recentFolders = recentFolders
        self.branchRow = branchRow
        self.explanation = explanation
    }

    /// A folder the menu lists.
    public struct Folder: Equatable, Sendable {
        public var url: URL
        public var title: String
        /// Where it is, with `~` for home: the menu's trailing column.
        public var path: String
        /// Whether it is the folder the draft has (the menu checks it).
        public var isChosen: Bool

        public init(url: URL, title: String, path: String, isChosen: Bool = false) {
            self.url = url
            self.title = title
            self.path = path
            self.isChosen = isChosen
        }
    }

    /// The row under the path.
    public enum BranchRow: Equatable, Sendable {
        /// A git folder: the branch pop-up's title and the Worktree toggle.
        case repository(branchTitle: String, usesWorktree: Bool)
        /// *Not a git repository*, worded, at the same height.
        case notARepository(String)
        /// The repository is still being read.
        case loading
    }
}
