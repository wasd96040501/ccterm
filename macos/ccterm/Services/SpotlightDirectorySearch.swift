import Foundation

enum SpotlightDirectorySearch {
    private static var currentQuery: NSMetadataQuery?
    private static var currentObserver: NSObjectProtocol?

    /// 搜索 scope 下名称包含 searchTerm 的文件夹，返回路径数组。
    /// limit 可以设大一些（如 100），后续由 fzf 做精排。
    static func search(query: String, scope: String = NSHomeDirectory(), limit: Int = 100,
                       completion: @escaping ([String]) -> Void) {
        cancel()

        let mdQuery = NSMetadataQuery()
        mdQuery.predicate = NSPredicate(
            format: "kMDItemContentType == 'public.folder' AND kMDItemFSName CONTAINS[cd] %@", query)
        mdQuery.searchScopes = [scope]

        currentQuery = mdQuery
        currentObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: mdQuery, queue: .main
        ) { _ in
            mdQuery.stop()
            let home = NSHomeDirectory()
            var paths: [String] = []
            paths.reserveCapacity(limit)
            for i in 0..<mdQuery.resultCount {
                guard paths.count < limit else { break }
                if let item = mdQuery.result(at: i) as? NSMetadataItem,
                   let path = item.value(forAttribute: kMDItemPath as String) as? String,
                   !isExcluded(path, home: home) {
                    paths.append(path)
                }
            }
            cleanup()
            completion(paths)
        }

        DispatchQueue.main.async { mdQuery.start() }
    }

    // MARK: - Filtering

    private static let excludedComponents: Set<String> = [
        "node_modules", ".git", "__pycache__", "DerivedData", ".build",
    ]

    private static func isExcluded(_ path: String, home: String) -> Bool {
        guard path.hasPrefix(home), path.count > home.count else { return false }
        let relative = String(path[path.index(path.startIndex, offsetBy: home.count + 1)...])

        // ~/Library
        if relative == "Library" || relative.hasPrefix("Library/") { return true }

        // ~/.<hidden> — top-level hidden dirs under home
        if relative.hasPrefix(".") { return true }

        // Component exact match anywhere in path
        let components = relative.split(separator: "/")
        for comp in components {
            if excludedComponents.contains(String(comp)) { return true }
        }

        return false
    }

    static func cancel() {
        currentQuery?.stop()
        cleanup()
    }

    private static func cleanup() {
        if let obs = currentObserver { NotificationCenter.default.removeObserver(obs) }
        currentObserver = nil
        currentQuery = nil
    }
}
