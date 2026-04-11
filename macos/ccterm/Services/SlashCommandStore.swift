import Cocoa
import AgentSDK

struct SlashCommand {
    let name: String
    let description: String?
    let isBuiltIn: Bool

    init(name: String, description: String?, isBuiltIn: Bool = false) {
        self.name = name
        self.description = description
        self.isBuiltIn = isBuiltIn
    }

    /// 从 InitializeResponse 解析
    static func from(_ response: InitializeResponse) -> [SlashCommand] {
        response.commands?.map {
            SlashCommand(name: $0.name, description: $0.description)
        } ?? []
    }
}

final class SlashCommandStore {

    // MARK: - Types

    struct Match: CompletionItem {
        let name: String        // 不含 "/" 前缀，如 "commit"
        let description: String?
        let rank: Int           // 越小越优先
        let isBuiltIn: Bool

        var displayText: String { "/\(name)" }
        var displayDetail: String? { description }
        var displayIcon: NSImage? {
            let symbolName = isBuiltIn ? "checkmark.circle.fill" : "terminal"
            return NSImage(systemSymbolName: symbolName, accessibilityDescription: "Command")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        }
    }

    /// 内置指令（不发送给 CLI）
    static func builtInCommands() -> [SlashCommand] {
        []
    }

    static let shared = SlashCommandStore()

    // MARK: - Properties

    private let fzfURL: URL
    private let queue = DispatchQueue(label: "com.ccterm.slash-command-store", qos: .userInitiated)
    private var cache: [CacheKey: CacheEntry] = [:]
    private var pendingCallbacks: [CacheKey: [([SlashCommand]) -> Void]] = [:]

    // MARK: - Lifecycle

    private init() {
        self.fzfURL = Bundle.main.url(forResource: "fzf", withExtension: nil)
            ?? URL(fileURLWithPath: "/usr/local/bin/fzf")
    }

    // MARK: - Public Methods

    func complete(
        query: String,
        path: String,
        pluginDirs: [String],
        knownCommands: [SlashCommand]?,
        completion: @escaping ([Match]) -> Void
    ) {
        NSLog("[SlashCmd] complete query='%@' path='%@' knownCommands=%@", query, path, knownCommands == nil ? "nil" : "\(knownCommands!.count) items")
        let builtIn = Self.builtInCommands()
        queue.async { [weak self] in
            guard let self else { return }

            if let known = knownCommands {
                let merged = builtIn + known
                let matches = self.matchCommands(query: query, commands: merged)
                NSLog("[SlashCmd] knownCommands fast path → %d matches", matches.count)
                DispatchQueue.main.async { completion(matches) }
                return
            }

            let key = CacheKey(path: path, pluginDirs: Set(pluginDirs))
            NSLog("[SlashCmd] resolveCommands for key cached=%d", self.cache[key] != nil ? 1 : 0)
            self.resolveCommands(for: key, pluginDirs: pluginDirs) { commands in
                let merged = builtIn + commands
                let matches = self.matchCommands(query: query, commands: merged)
                NSLog("[SlashCmd] resolved → %d commands, %d matches", commands.count, matches.count)
                DispatchQueue.main.async { completion(matches) }
            }
        }
    }

    func invalidateAll() {
        queue.async { [weak self] in
            self?.cache.removeAll()
        }
    }

    // MARK: - Private Methods

    /// 查缓存 → 合并请求 → 或启动 CLI。在 self.queue 上调用。
    private func resolveCommands(for key: CacheKey, pluginDirs: [String], callback: @escaping ([SlashCommand]) -> Void) {
        if let entry = cache[key] {
            callback(entry.commands)
            return
        }

        // 合并：同一个 key 的 CLI 正在加载中，追加 callback 即可
        if pendingCallbacks[key] != nil {
            pendingCallbacks[key]!.append(callback)
            return
        }

        pendingCallbacks[key] = [callback]
        launchTempCLI(for: key, pluginDirs: pluginDirs)
    }

    /// 启动临时 CLI，通过 initialize control_request 获取 commands（含 description）。
    private func launchTempCLI(for key: CacheKey, pluginDirs: [String]) {
        let config = SessionConfiguration(
            workingDirectory: URL(fileURLWithPath: key.path),
            plugins: pluginDirs
        )
        let session = AgentSDK.Session(configuration: config)

        session.onProcessExit = { [weak self] exitCode in
            guard let self else { return }
            self.queue.async {
                if self.pendingCallbacks[key] != nil {
                    NSLog("[SlashCommandStore] Temp CLI exited (%d) before initialize response for %@", exitCode, key.path)
                    self.didFinishLoad(key: key, commands: [], pluginDirs: pluginDirs)
                }
            }
        }

        Task {
            do {
                try await session.start()
                session.initialize(promptSuggestions: true) { [weak self] response in
                    guard let self else { return }
                    let commands = response.map { SlashCommand.from($0) } ?? []
                    session.stop()
                    self.queue.async {
                        self.didFinishLoad(key: key, commands: commands, pluginDirs: pluginDirs)
                    }
                }
            } catch {
                NSLog("[SlashCommandStore] Failed to start temp CLI: %@", "\(error)")
                self.queue.async { [weak self] in
                    self?.didFinishLoad(key: key, commands: [], pluginDirs: pluginDirs)
                }
            }
        }
    }

    /// 写入缓存、启动监听、排空回调。在 self.queue 上调用。
    private func didFinishLoad(key: CacheKey, commands: [SlashCommand], pluginDirs: [String]) {
        let monitors = buildMonitors(for: key, pluginDirs: pluginDirs)
        cache[key] = CacheEntry(commands: commands, monitors: monitors)

        if let callbacks = pendingCallbacks.removeValue(forKey: key) {
            for cb in callbacks {
                cb(commands)
            }
        }
    }

    private func buildMonitors(for key: CacheKey, pluginDirs: [String]) -> [DirectoryTreeMonitor] {
        let home = NSHomeDirectory()
        var dirs = [
            "\(home)/.claude/skills",
            "\(home)/.claude/commands",
            "\(key.path)/.claude/skills",
            "\(key.path)/.claude/commands",
        ]
        for pluginDir in pluginDirs {
            dirs.append("\(pluginDir)/skills")
        }

        let fm = FileManager.default
        var monitors: [DirectoryTreeMonitor] = []
        for dir in dirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }

            let monitor = DirectoryTreeMonitor(
                directory: URL(fileURLWithPath: dir),
                latency: 2.0
            ) { [weak self] _ in
                self?.queue.async {
                    self?.cache.removeValue(forKey: key)
                }
            }
            monitor.start()
            monitors.append(monitor)
        }
        return monitors
    }

    /// 在 self.queue 上调用。
    private func matchCommands(query: String, commands: [SlashCommand], limit: Int = 20) -> [Match] {
        if query.isEmpty {
            return commands.prefix(limit).enumerated().map {
                Match(name: $1.name, description: $1.description, rank: $0, isBuiltIn: $1.isBuiltIn)
            }
        }
        let names = commands.map(\.name)
        let descMap = Dictionary(uniqueKeysWithValues: commands.map { ($0.name, $0.description) })
        let builtInMap = Dictionary(uniqueKeysWithValues: commands.map { ($0.name, $0.isBuiltIn) })
        return runFzf(query: query, commands: names, limit: limit).map {
            Match(name: $0.name, description: descMap[$0.name] ?? nil, rank: $0.rank, isBuiltIn: builtInMap[$0.name] ?? false)
        }
    }

    /// 调用 fzf --filter 模糊匹配。在 self.queue 上调用。返回的 Match.description 为 nil。
    private func runFzf(query: String, commands: [String], limit: Int) -> [Match] {
        guard !commands.isEmpty else { return [] }

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
        } catch {
            return []
        }

        let input = commands.joined(separator: "\n")
        inputPipe.fileHandleForWriting.write(input.data(using: .utf8)!)
        inputPipe.fileHandleForWriting.closeFile()

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .prefix(limit)
            .enumerated()
            .map { Match(name: $1, description: nil, rank: $0, isBuiltIn: false) }
    }
}

// MARK: - Private Types

private extension SlashCommandStore {

    struct CacheKey: Hashable {
        let path: String
        let pluginDirs: Set<String>
    }

    struct CacheEntry {
        let commands: [SlashCommand]
        let monitors: [DirectoryTreeMonitor]
    }
}
