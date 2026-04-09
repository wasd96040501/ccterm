import Foundation

enum DirectoryCompletionProvider {

    /// Unified entry point: empty → recent only; non-empty → Spotlight + recent → fzf ranking.
    static func provide(query: String, completion: @escaping ([any CompletionItem]) -> Void) {
        if query.isEmpty {
            // 空查询：只显示最近目录，不走 Spotlight/fzf
            DispatchQueue.global(qos: .userInitiated).async {
                let items = loadRecentFolders().compactMap { path -> DirectoryCompletionItem? in
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                          isDir.boolValue else { return nil }
                    return DirectoryCompletionItem(path: path, isRecent: true)
                }
                DispatchQueue.main.async { completion(items) }
            }
            return
        }

        // 非空查询：Spotlight 搜候选 → 合并 recent → fzf 统一排序
        let searchTerm = extractSearchTerm(from: query)

        SpotlightDirectorySearch.search(query: searchTerm) { spotlightPaths in
            DispatchQueue.global(qos: .userInitiated).async {
                // 合并 recent + Spotlight，去重
                var seen = Set<String>()
                var allPaths: [String] = []

                // recent 优先（fzf 会重新排序，但出现在候选池中就行）
                for path in loadRecentFolders() {
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                          isDir.boolValue, seen.insert(path).inserted else { continue }
                    allPaths.append(path)
                }
                for path in spotlightPaths where seen.insert(path).inserted {
                    allPaths.append(path)
                }

                // 转为显示路径（~/...），用 fzf 做模糊匹配 + 排序
                let home = NSHomeDirectory()
                let displayPaths = allPaths.map { path -> String in
                    path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
                }

                let recentSet = Set(loadRecentFolders())
                let ranked = fzfFilter(query: query, items: displayPaths)

                let allItems: [DirectoryCompletionItem] = ranked.compactMap { displayPath in
                    let fullPath: String
                    if displayPath.hasPrefix("~") {
                        fullPath = home + displayPath.dropFirst(1)
                    } else {
                        fullPath = displayPath
                    }
                    return DirectoryCompletionItem(path: fullPath, isRecent: recentSet.contains(fullPath))
                }

                // Recent items first (preserving fzf order within each group)
                let recentItems = allItems.filter { $0.isRecent }
                let otherItems = allItems.filter { !$0.isRecent }
                let items = recentItems + otherItems

                DispatchQueue.main.async { completion(items) }
            }
        }
    }

    /// Save a path to recent list (deduplicate, move to top, cap at 20).
    static func saveToRecent(_ path: String) {
        let key = "folderPickerRecent"
        var paths = loadRecentFolders()
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > 20 { paths = Array(paths.prefix(20)) }
        if let data = try? JSONEncoder().encode(paths) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

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
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return paths
    }

    /// 从用户输入提取 Spotlight 搜索词。
    /// "code/my-proj" → "my-proj"，"Documents" → "Documents"
    private static func extractSearchTerm(from query: String) -> String {
        let q = query.hasPrefix("~") ? String(query.dropFirst()) : query
        let trimmed = q.hasPrefix("/") ? String(q.dropFirst()) : q
        let components = trimmed.components(separatedBy: "/").filter { !$0.isEmpty }
        return components.last ?? trimmed
    }

    /// 调用 fzf --filter 做模糊排序，返回排序后的显示路径。
    private static func fzfFilter(query: String, items: [String]) -> [String] {
        guard !items.isEmpty else { return [] }

        let fzfURL = Bundle.main.url(forResource: "fzf", withExtension: nil)
            ?? URL(fileURLWithPath: "/usr/local/bin/fzf")
        guard FileManager.default.fileExists(atPath: fzfURL.path) else { return items }

        let process = Process()
        process.executableURL = fzfURL
        process.arguments = ["--filter", query]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let input = items.joined(separator: "\n")
            inputPipe.fileHandleForWriting.write(input.data(using: .utf8)!)
            inputPipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .components(separatedBy: "\n")
                .filter { !$0.isEmpty }
                ?? []
        } catch {
            return []
        }
    }
}
