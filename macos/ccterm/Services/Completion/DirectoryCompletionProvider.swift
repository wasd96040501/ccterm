import Foundation

enum DirectoryCompletionProvider {

    /// Remove a path from recent list.
    static func removeFromRecent(_ path: String) {
        let key = "folderPickerRecent"
        var paths = loadRecentFolders()
        paths.removeAll { $0 == path }
        if let data = try? JSONEncoder().encode(paths) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: - Internal

    static func loadRecentFolders() -> [String] {
        let key = "folderPickerRecent"
        guard let data = UserDefaults.standard.data(forKey: key),
            let paths = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return paths
    }
}
