import Cocoa
import UniformTypeIdentifiers

/// 管理所有 cwd 的文件列表缓存，提供 fzf 模糊补全。
/// 懒加载：首次请求某 cwd 时加载文件列表并开始监听变化。
final class FileCompletionStore {

    // MARK: - Types

    struct Match: CompletionItem {
        let path: String
        /// fzf 排序位置，越小越靠前（query 为空时为 0）
        let rank: Int
        /// 来源目录名（多文件夹模式下显示为 badge）
        let sourceDir: String?

        init(path: String, rank: Int, sourceDir: String? = nil) {
            self.path = path
            self.rank = rank
            self.sourceDir = sourceDir
        }

        var displayText: String { path }
        var displayDetail: String? { nil }
        var displayBadge: String? { sourceDir }
        var displayIcon: NSImage? {
            if path.hasSuffix("/") {
                return NSWorkspace.shared.icon(for: .folder)
            }
            let ext = (path as NSString).pathExtension
            if ext.isEmpty { return NSWorkspace.shared.icon(for: .plainText) }
            if let utType = UTType(filenameExtension: ext) {
                return NSWorkspace.shared.icon(for: utType)
            }
            return NSWorkspace.shared.icon(for: .plainText)
        }
    }

    static let shared = FileCompletionStore()

    // MARK: - Properties

    private let fzfURL: URL
    private var entries: [String: Entry] = [:]
    private let queue = DispatchQueue(label: "com.ccterm.file-completion-store", qos: .userInitiated)

    // MARK: - Lifecycle

    init() {
        self.fzfURL = Bundle.main.url(forResource: "fzf", withExtension: nil)
            ?? URL(fileURLWithPath: "/usr/local/bin/fzf")
    }

    // MARK: - Public Methods

    /// 模糊匹配文件名。首次调用某 cwd 会触发懒加载 + 监听。
    /// - Parameters:
    ///   - query: @ 后的查询字符串，可为空
    ///   - directory: 工作目录
    ///   - limit: 最大返回条数
    ///   - completion: 主线程回调
    func complete(query: String, in directory: String, limit: Int = 20, completion: @escaping ([Match]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let files = self.ensureLoaded(directory: directory)

            let results: [Match]
            if query.isEmpty {
                results = files.prefix(limit).map { Match(path: $0, rank: 0) }
            } else {
                let inputFile = self.ensureFzfInputFile(for: directory)
                results = self.runFzf(query: query, inputFile: inputFile, files: files, limit: limit)
            }

            DispatchQueue.main.async {
                completion(results)
            }
        }
    }

    /// 多文件夹模糊匹配：合并所有目录的文件列表后单次 fzf 调用，结果附带来源目录 badge。
    func complete(query: String, in directories: [String], limit: Int = 20, completion: @escaping ([Match]) -> Void) {
        guard !directories.isEmpty else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        if directories.count == 1 {
            complete(query: query, in: directories[0], limit: limit, completion: completion)
            return
        }
        queue.async { [weak self] in
            guard let self else { return }

            // Tag each file with its source directory index: "0\tpath/to/file"
            var taggedFiles: [String] = []
            var dirNames: [String] = []
            for (index, dir) in directories.enumerated() {
                let files = self.ensureLoaded(directory: dir)
                let dirName = (dir as NSString).lastPathComponent
                dirNames.append(dirName)
                for file in files {
                    taggedFiles.append("\(index)\t\(file)")
                }
            }

            let results: [Match]
            if query.isEmpty {
                results = taggedFiles.prefix(limit).compactMap { line -> Match? in
                    guard let tabIdx = line.firstIndex(of: "\t") else { return nil }
                    let idx = Int(line[line.startIndex..<tabIdx]) ?? 0
                    let path = String(line[line.index(after: tabIdx)...])
                    return Match(path: path, rank: 0, sourceDir: dirNames[idx])
                }
            } else {
                // Run single fzf with --delimiter and --nth to match only on file path (not tag)
                results = self.runFzfTagged(query: query, taggedFiles: taggedFiles, dirNames: dirNames, limit: limit)
            }

            DispatchQueue.main.async {
                completion(results)
            }
        }
    }

    /// 移除指定 cwd 的缓存和监听
    func invalidate(directory: String) {
        queue.async { [weak self] in
            self?.entries.removeValue(forKey: directory)
        }
    }

    /// 移除所有缓存和监听
    func invalidateAll() {
        queue.async { [weak self] in
            self?.entries.removeAll()
        }
    }

    // MARK: - Private Methods

    /// 确保指定目录已加载，返回文件列表
    private func ensureLoaded(directory: String) -> [String] {
        if let entry = entries[directory] {
            return entry.files
        }
        let files = loadFileList(directory: directory)
        let monitor = DirectoryTreeMonitor(
            directory: URL(fileURLWithPath: directory),
            latency: 1.0
        ) { [weak self] events in
            self?.handleFSEvents(events, directory: directory)
        }
        monitor.start()
        entries[directory] = Entry(files: files, monitor: monitor)
        return files
    }

    /// 处理文件系统事件：增量更新缓存
    private func handleFSEvents(_ events: [DirectoryTreeMonitor.Event], directory: String) {
        queue.async { [weak self] in
            guard let self, var entry = self.entries[directory] else { return }
            let prefix = directory.hasSuffix("/") ? directory : directory + "/"

            for event in events {
                switch event {
                case .fileCreated(let url):
                    let relative = self.relativePath(url: url, prefix: prefix)
                    if !entry.files.contains(relative) {
                        entry.files.append(relative)
                    }
                case .fileRemoved(let url):
                    let relative = self.relativePath(url: url, prefix: prefix)
                    entry.files.removeAll { $0 == relative }
                case .directoryCreated(let url):
                    let relative = self.relativePath(url: url, prefix: prefix) + "/"
                    if !entry.files.contains(relative) {
                        entry.files.append(relative)
                    }
                case .directoryRemoved(let url):
                    let relative = self.relativePath(url: url, prefix: prefix) + "/"
                    entry.files.removeAll { $0 == relative || $0.hasPrefix(relative) }
                default:
                    break
                }
            }
            entry.fzfInputFile = nil
            self.entries[directory] = entry
        }
    }

    private func relativePath(url: URL, prefix: String) -> String {
        let path = url.path
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return path
    }

    /// 加载文件列表（git ls-files，fallback 到 find），并提取目录
    private func loadFileList(directory: String) -> [String] {
        let files = gitLsFiles(directory: directory) ?? findFiles(directory: directory)
        let dirs = extractDirectories(from: files)
        return dirs + files
    }

    /// 从文件路径中提取所有中间目录（去重，带 / 后缀）
    private func extractDirectories(from files: [String]) -> [String] {
        var dirSet = Set<String>()
        for file in files {
            var path = file as NSString
            while true {
                let parent = path.deletingLastPathComponent
                if parent.isEmpty || parent == "." { break }
                let dir = parent + "/"
                if dirSet.contains(dir) { break }
                dirSet.insert(dir)
                path = parent as NSString
            }
        }
        return dirSet.sorted()
    }

    private func gitLsFiles(directory: String) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.quotePath=false", "ls-files", "--cached", "--others", "--exclude-standard"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read before waitUntilExit to avoid deadlock when output exceeds pipe buffer
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        return output.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private func findFiles(directory: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        process.arguments = [".", "-type", "f",
                             "-not", "-path", "./.git/*",
                             "-not", "-path", "./node_modules/*",
                             "-not", "-path", "./.build/*",
                             "-maxdepth", "8"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        // Read before waitUntilExit to avoid deadlock when output exceeds pipe buffer
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 }
    }

    /// 确保 fzf 临时输入文件存在，不存在则写入
    private func ensureFzfInputFile(for directory: String) -> URL? {
        if let url = entries[directory]?.fzfInputFile {
            return url
        }
        guard let entry = entries[directory], !entry.files.isEmpty else { return nil }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ccterm-fzf-\(directory.hashValue)")
        let content = entry.files.joined(separator: "\n")
        guard (try? content.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        entries[directory]?.fzfInputFile = url
        return url
    }

    /// 单次 fzf 调用，输入为 "dirIndex\tpath" 格式，--nth 2 只匹配路径部分
    private func runFzfTagged(query: String, taggedFiles: [String], dirNames: [String], limit: Int) -> [Match] {
        guard !taggedFiles.isEmpty else { return [] }

        let process = Process()
        process.executableURL = fzfURL
        process.arguments = ["--filter", query, "--delimiter", "\t", "--nth", "2"]

        let inputPipe = Pipe()
        process.standardInput = inputPipe
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let input = taggedFiles.joined(separator: "\n")
        inputPipe.fileHandleForWriting.write(input.data(using: .utf8)!)
        inputPipe.fileHandleForWriting.closeFile()

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .prefix(limit)
            .enumerated()
            .compactMap { (rank, line) -> Match? in
                guard let tabIdx = line.firstIndex(of: "\t") else { return nil }
                let dirIdx = Int(line[line.startIndex..<tabIdx]) ?? 0
                let path = String(line[line.index(after: tabIdx)...])
                let dirName = dirIdx < dirNames.count ? dirNames[dirIdx] : ""
                return Match(path: path, rank: rank, sourceDir: dirName)
            }
    }

    /// 调用 fzf --filter 进行模糊匹配
    private func runFzf(query: String, inputFile: URL?, files: [String], limit: Int) -> [Match] {
        guard !files.isEmpty else { return [] }

        let process = Process()
        process.executableURL = fzfURL
        process.arguments = ["--filter", query]

        let pipeFallback: Pipe?
        if let inputFile, let handle = FileHandle(forReadingAtPath: inputFile.path) {
            process.standardInput = handle
            pipeFallback = nil
        } else {
            if inputFile != nil {
                NSLog("[FileCompletionStore] fzf input file unavailable, falling back to pipe")
            }
            let pipe = Pipe()
            process.standardInput = pipe
            pipeFallback = pipe
        }

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        if let pipeFallback {
            let input = files.joined(separator: "\n")
            pipeFallback.fileHandleForWriting.write(input.data(using: .utf8)!)
            pipeFallback.fileHandleForWriting.closeFile()
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .prefix(limit)
            .enumerated()
            .map { Match(path: $1, rank: $0) }
    }
}

// MARK: - Entry

private extension FileCompletionStore {
    struct Entry {
        var files: [String]
        let monitor: DirectoryTreeMonitor
        var fzfInputFile: URL?
    }
}
