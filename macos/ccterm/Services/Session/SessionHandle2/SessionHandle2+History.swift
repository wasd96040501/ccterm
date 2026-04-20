import Foundation
import AgentSDK

// MARK: - JSONL path resolution

extension SessionHandle2 {

    /// Claude CLI 的 live JSONL 目录（`~/.claude/projects/<slug>/<sessionId>.jsonl`）。
    nonisolated static var claudeProjectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    /// CCTerm 自建的 export JSONL 目录（含完整 stdio 消息）。优先使用。
    nonisolated static var exportRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/ccterm/export")
    }

    /// 本 session 的历史 JSONL URL。export 优先；不存在则回落到 live；再不存在则 nil。
    /// slug 需要 repository 里的 cwd，所以 `activate()` 之前 resume 也能拿到。
    var historyJSONLURL: URL? {
        let export = Self.exportRoot.appendingPathComponent("\(sessionId).jsonl")
        if FileManager.default.fileExists(atPath: export.path) { return export }

        guard let rec = repository.find(sessionId), let slug = rec.slug else { return nil }
        let live = Self.claudeProjectsRoot
            .appendingPathComponent(slug)
            .appendingPathComponent("\(sessionId).jsonl")
        return FileManager.default.fileExists(atPath: live.path) ? live : nil
    }
}

// MARK: - loadHistory

extension SessionHandle2 {

    /// 后台加载历史消息 → 回主线程逐条喂 `receive(_:mode:.replay)`。
    /// 幂等：`.loading` / `.loaded` 直接返回；`.failed` 视为重试。
    /// 与 `activate()` 完全正交——stopped / notStarted session 也能查看历史。
    ///
    /// - Parameter url: 可选路径覆盖，仅测试使用；生产代码调 `loadHistory()` 走默认解析。
    func loadHistory(overrideURL url: URL? = nil) {
        switch historyLoadState {
        case .loading, .loaded:
            return
        case .failed:
            historyLoadState = .notLoaded
        case .notLoaded:
            break
        }
        historyLoadState = .loading

        let resolved = url ?? historyJSONLURL
        appLog(.info, "SessionHandle2", "loadHistory begin \(sessionId) url=\(resolved?.path ?? "(none)")")

        Task.detached {
            let result = Self.parseJSONL(at: resolved)
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let msgs):
                    for m in msgs { self.receive(m, mode: .replay) }
                    self.historyLoadState = .loaded
                    appLog(.info, "SessionHandle2", "loadHistory done \(self.sessionId) count=\(msgs.count)")
                case .failure(let err):
                    self.historyLoadState = .failed(err.localizedDescription)
                    appLog(.warning, "SessionHandle2", "loadHistory FAILED \(self.sessionId) err=\(err.localizedDescription)")
                }
            }
        }
    }

    /// 纯函数：把 JSONL 文件解析为 `[Message2]`。url == nil 或文件不存在视为"无历史"
    /// 返回 `.success([])`（属于正常态，非 failed）。解析错误（I/O / 编码）→ `.failure`。
    nonisolated static func parseJSONL(at url: URL?) -> Result<[Message2], Error> {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return .success([])
        }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                return .failure(HistoryParseError.invalidUTF8)
            }
            let resolver = Message2Resolver()
            var messages: [Message2] = []
            for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let msg = try? resolver.resolve(json) else {
                    continue
                }
                messages.append(msg)
            }
            return .success(messages)
        } catch {
            return .failure(error)
        }
    }

    enum HistoryParseError: LocalizedError {
        case invalidUTF8

        var errorDescription: String? {
            switch self {
            case .invalidUTF8: return "History JSONL is not valid UTF-8"
            }
        }
    }
}
