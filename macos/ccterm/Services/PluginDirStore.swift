import Foundation

/// Manages plugin directory persistence in UserDefaults.
enum PluginDirStore {

    private static let directoriesKey = "pluginDirectories"
    private static let enabledKey = "enabledPluginDirectories"
    private static let perPathKey = "pluginDirectoriesPerPath"

    // MARK: - All Directories

    static var directories: [String] {
        get { UserDefaults.standard.stringArray(forKey: directoriesKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: directoriesKey) }
    }

    // MARK: - Enabled Directories (global default)

    static var enabledDirectories: [String] {
        get {
            let enabled = Set(UserDefaults.standard.stringArray(forKey: enabledKey) ?? [])
            // Only return paths that still exist in the directories list
            return directories.filter { enabled.contains($0) }
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var enabledSet: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: enabledKey) ?? [])
    }

    // MARK: - Per-Path Enabled Directories

    /// Returns enabled plugin dirs for a given working directory path.
    /// Falls back to global enabledDirectories if no per-path record exists.
    static func enabledDirectories(forPath path: String) -> [String] {
        guard let perPath = UserDefaults.standard.dictionary(forKey: perPathKey),
              let saved = perPath[path] as? [String] else {
            return enabledDirectories
        }
        // Filter to only dirs that still exist in the global directories list
        let allDirs = Set(directories)
        return saved.filter { allDirs.contains($0) }
    }

    /// Returns enabled set for a given working directory path.
    static func enabledSet(forPath path: String) -> Set<String> {
        Set(enabledDirectories(forPath: path))
    }

    /// Saves the enabled plugin dirs for a specific working directory path.
    static func saveEnabledDirectories(_ plugins: [String], forPath path: String) {
        var perPath = UserDefaults.standard.dictionary(forKey: perPathKey) ?? [:]
        perPath[path] = plugins
        UserDefaults.standard.set(perPath, forKey: perPathKey)
    }

    // MARK: - Mutations

    static func addDirectory(_ path: String) {
        var dirs = directories
        guard !dirs.contains(path) else { return }
        dirs.append(path)
        directories = dirs
        // Auto-enable newly added directory
        var enabled = enabledSet
        enabled.insert(path)
        enabledDirectories = Array(enabled)
    }

    static func removeDirectory(_ path: String) {
        var dirs = directories
        dirs.removeAll { $0 == path }
        directories = dirs
        var enabled = enabledSet
        enabled.remove(path)
        enabledDirectories = Array(enabled)
    }

    static func setEnabled(_ path: String, enabled: Bool) {
        var set = enabledSet
        if enabled {
            set.insert(path)
        } else {
            set.remove(path)
        }
        enabledDirectories = Array(set)
    }
}
