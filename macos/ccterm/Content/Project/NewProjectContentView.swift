import Foundation

/// Data model for a folder entry in the new project card list.
struct ProjectFolder {
    let path: String
    var branch: String?
    var isGit: Bool
    var isWorktree: Bool

    var displayName: String {
        (path as NSString).lastPathComponent
    }
}
