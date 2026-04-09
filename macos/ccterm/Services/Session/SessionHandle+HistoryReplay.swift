import Foundation
import AgentSDK

// MARK: - HistoryLoadState

extension SessionHandle {

    /// 历史消息加载状态。UI 通过观察此属性决定展示 loading indicator 还是消息列表。
    enum HistoryLoadState {
        /// 尚未触发加载。
        case notLoaded
        /// 后台加载中。
        case loading
        /// 加载完成。messages 可能为空（该会话确实没有消息），但已就绪。
        case loaded
    }
}

// MARK: - JSONL Path

extension SessionHandle {

    /// Claude 项目根目录。将来可能支持动态配置。
    nonisolated static var claudeProjectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    /// 该会话的 JSONL 文件路径。通过 slug 精确定位，不遍历目录。
    var jsonlFileURL: URL? {
        guard let record = repository.find(sessionId),
              let slug = record.slug else { return nil }
        return Self.claudeProjectsRoot
            .appendingPathComponent(slug)
            .appendingPathComponent("\(sessionId).jsonl")
    }

    /// Export JSONL 路径。包含完整 stdio 消息（含 result），优先用于历史回放。
    private static let exportRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/ccterm/export")

    var exportJSONLFileURL: URL {
        Self.exportRoot.appendingPathComponent("\(sessionId).jsonl")
    }
}

// MARK: - Lazy Loading

extension SessionHandle {

    /// 懒加载历史消息。后台过滤 JSONL，批量发送 raw JSON 到 React。
    /// 仅在 historyLoadState == .notLoaded 时触发，重复调用无效果。
    /// - Parameter completion: 消息加载完成并发送到 React 后在主线程回调。
    func loadHistoryIfNeeded(completion: (() -> Void)? = nil) {
        guard historyLoadState == .notLoaded else {
            completion?()
            return
        }
        historyLoadState = .loading

        // 优先用 export JSONL（含 result 消息，能提取 contextWindow）
        let exportURL = exportJSONLFileURL
        let fileURL = FileManager.default.fileExists(atPath: exportURL.path) ? exportURL : jsonlFileURL
        let sessionCwd = repository.find(sessionId)?.cwd

        Task.detached {
            let (jsons, finalState) = Self.replayJSONL(from: fileURL, cwd: sessionCwd)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.filterState = finalState
                if let usage = finalState.contextUsageSnapshot {
                    self.contextUsedTokens = usage.usedTokens
                    self.contextWindowTokens = usage.windowTokens
                }
                self.bridge?.setRawMessages(conversationId: self.sessionId, messagesJSON: jsons)
                self.historyLoadState = .loaded
                completion?()
            }
        }
    }
}

// MARK: - JSONL Replay (后台线程，纯函数)

extension SessionHandle {

    /// 从 JSONL 文件回放为过滤后的 raw JSON 数组。由 React adapter 转换渲染。
    nonisolated static func replayJSONL(
        from fileURL: URL?,
        cwd: String?
    ) -> ([[String: Any]], MessageFilter.State) {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            return ([], MessageFilter.State())
        }

        var filterState = MessageFilter.State()
        var jsons: [[String: Any]] = []

        let resolver = Message2Resolver()
        for line in content.components(separatedBy: .newlines) {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = try? resolver.resolve(json) else {
                continue
            }
            let result = MessageFilter.filter(message, state: &filterState)
            if result.shouldForward {
                jsons.append(json)
            }
        }

        return (jsons, filterState)
    }
}
