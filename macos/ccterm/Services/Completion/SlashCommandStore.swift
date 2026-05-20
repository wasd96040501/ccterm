import AgentSDK
import Cocoa

/// Per-directory cache of slash commands for the `/`-completion popup.
///
/// In chat mode the session's `slashCommands` (populated by the CLI's
/// `initialize` response) is the authoritative source — callers pass it
/// via `knownCommands` and `complete(...)` takes a fast synchronous
/// path. In compose mode there is no running CLI yet, so the store
/// spins up a short-lived `AgentSDK.Session`, drives a single
/// `initialize(promptSuggestions: true)`, caches the response, and
/// stops the subprocess. Cache invalidation is FSEvents-driven on the
/// usual `.claude/skills` / `.claude/commands` directories under both
/// `$HOME` and the working path.
final class SlashCommandStore {

    // MARK: - Types

    struct Match: CompletionItem {
        let name: String  // without "/", e.g. "commit"
        let description: String?
        let rank: Int

        var displayText: String { "/\(name)" }
        var displayDetail: String? { description }
        var displayIcon: NSImage? {
            NSImage(systemSymbolName: "terminal", accessibilityDescription: "Command")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        }
    }

    static let shared = SlashCommandStore()

    // MARK: - Properties

    private let fzfURL: URL
    private let queue = DispatchQueue(label: "com.ccterm.slash-command-store", qos: .userInitiated)
    private var cache: [CacheKey: CacheEntry] = [:]
    private var pendingCallbacks: [CacheKey: [([SlashCommand]) -> Void]] = [:]

    // MARK: - Lifecycle

    private init() {
        self.fzfURL =
            Bundle.main.url(forResource: "fzf", withExtension: nil)
            ?? URL(fileURLWithPath: "/usr/local/bin/fzf")
    }

    // MARK: - Public Methods

    /// Pre-warm the cache for a path + plugin-dir combination. Triggers
    /// the temp-CLI initialize fetch in the background if no entry is
    /// cached yet. Idempotent; queue serialization makes subsequent
    /// `complete(...)` calls block behind a pending warm.
    func warm(path: String, pluginDirs: [String]) {
        queue.async { [weak self] in
            guard let self else { return }
            let key = CacheKey(path: path, pluginDirs: Set(pluginDirs))
            guard self.cache[key] == nil, self.pendingCallbacks[key] == nil else { return }
            self.pendingCallbacks[key] = []
            self.launchTempCLI(for: key, pluginDirs: pluginDirs)
        }
    }

    /// Filter the slash command list for `query` and call back on the
    /// main queue with `Match`es. When `knownCommands` is provided the
    /// path / pluginDirs are ignored and the filter is synchronous —
    /// chat-mode sessions already have the command list from the CLI's
    /// initialize response so paying for a temp-CLI fetch would be
    /// wasteful.
    func complete(
        query: String,
        path: String,
        pluginDirs: [String],
        knownCommands: [SlashCommand]?,
        completion: @escaping ([Match]) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }

            if let known = knownCommands {
                let matches = self.matchCommands(query: query, commands: known)
                DispatchQueue.main.async { completion(matches) }
                return
            }

            let key = CacheKey(path: path, pluginDirs: Set(pluginDirs))
            self.resolveCommands(for: key, pluginDirs: pluginDirs) { commands in
                let matches = self.matchCommands(query: query, commands: commands)
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

    /// Lookup the cache or coalesce into a pending fetch. Always called on `self.queue`.
    private func resolveCommands(for key: CacheKey, pluginDirs: [String], callback: @escaping ([SlashCommand]) -> Void)
    {
        if let entry = cache[key] {
            callback(entry.commands)
            return
        }

        if pendingCallbacks[key] != nil {
            pendingCallbacks[key]!.append(callback)
            return
        }

        pendingCallbacks[key] = [callback]
        launchTempCLI(for: key, pluginDirs: pluginDirs)
    }

    /// Launch a one-shot CLI to fetch slash commands via `initialize`.
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
                    appLog(
                        .error, "SlashCommandStore",
                        "Temp CLI exited (\(exitCode)) before initialize response for \(key.path)")
                    self.didFinishLoad(key: key, commands: [], pluginDirs: pluginDirs)
                }
            }
        }

        Task {
            do {
                try await session.start()
                session.initialize(promptSuggestions: true) { [weak self] response in
                    guard let self else { return }
                    let commands: [SlashCommand] =
                        response?.commands?
                        .map { SlashCommand(name: $0.name, description: $0.description) } ?? []
                    session.stop()
                    self.queue.async {
                        self.didFinishLoad(key: key, commands: commands, pluginDirs: pluginDirs)
                    }
                }
            } catch {
                appLog(.error, "SlashCommandStore", "Failed to start temp CLI: \(error)")
                self.queue.async { [weak self] in
                    self?.didFinishLoad(key: key, commands: [], pluginDirs: pluginDirs)
                }
            }
        }
    }

    /// Persist the fetched commands, set up the invalidation monitors,
    /// and drain any callers waiting on the same key. On `self.queue`.
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

    /// Substring filter for slash command names. Lists are small (~20
    /// entries) so we skip fzf and avoid a subprocess on every keystroke.
    /// On `self.queue`.
    private func matchCommands(query: String, commands: [SlashCommand], limit: Int = 20) -> [Match] {
        let trimmed = query.lowercased()
        let filtered: [SlashCommand]
        if trimmed.isEmpty {
            filtered = commands
        } else {
            filtered = commands.filter { $0.name.lowercased().contains(trimmed) }
        }
        return filtered.prefix(limit).enumerated().map { idx, cmd in
            Match(name: cmd.name, description: cmd.description, rank: idx)
        }
    }
}

// MARK: - Private Types

extension SlashCommandStore {

    fileprivate struct CacheKey: Hashable {
        let path: String
        let pluginDirs: Set<String>
    }

    fileprivate struct CacheEntry {
        let commands: [SlashCommand]
        let monitors: [DirectoryTreeMonitor]
    }
}
