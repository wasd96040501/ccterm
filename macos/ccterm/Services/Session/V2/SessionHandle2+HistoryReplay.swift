import Foundation
import AgentSDK

/// 历史消息懒加载。后台读取 JSONL，原始转发给 bridge（React 自行过滤显示）。
///
/// 仅对 inactive 会话有意义——live 会话走 CLI 推送路径。
extension SessionHandle2 {

    /// 懒加载历史消息。并发调用合流到同一次加载，所有 completion 在加载真正结束后统一 fire。
    /// - Parameters:
    ///   - jsonlFileURL: JSONL 文件路径（由调用方提供，一般来自 SessionRecord.slug）。
    ///     为 nil 或文件不存在时视为空历史。
    ///   - completion: 加载并推送完成后在主线程回调。.loaded / live 会话立即回调。
    func loadHistoryIfNeeded(
        jsonlFileURL: URL?,
        completion: (() -> Void)? = nil
    ) {
        switch historyLoadState {
        case .loaded:
            completion?()
            return
        case .loading:
            if let completion { historyLoadWaiters.append(completion) }
            return
        case .notLoaded:
            break
        }

        // live 会话没有 JSONL 历史要回放——直接标记为 loaded。
        guard status == .inactive else {
            appLog(.info, "SessionHandle2", "loadHistory skipped — live session \(sessionId)")
            historyLoadState = .loaded
            completion?()
            return
        }

        historyLoadState = .loading
        if let completion { historyLoadWaiters.append(completion) }

        Task.detached { [sessionId] in
            let result = Self.replayJSONL(from: jsonlFileURL)
            await MainActor.run { [weak self] in
                guard let self else { return }
                // 加载期间被 attach 抢占则放弃本次结果，避免覆盖 live 的 modelContextWindows。
                // 抢占路径（见 attach）会自行 fire 并清空 waiters。
                guard self.historyLoadState == .loading else { return }
                self.modelContextWindows = result.modelContextWindows
                if let usage = result.contextUsage {
                    self.contextUsage = usage
                }
                self.bridge?.setRawMessages(conversationId: sessionId, messagesJSON: result.jsons)
                self.historyLoadState = .loaded
                let waiters = self.historyLoadWaiters
                self.historyLoadWaiters.removeAll()
                for waiter in waiters { waiter() }
            }
        }
    }

    /// 后台安全的 JSONL 回放：解析 → 全部转发 → 计算最终 contextUsage 快照与 window 缓存。
    nonisolated static func replayJSONL(
        from fileURL: URL?
    ) -> (jsons: [[String: Any]], modelContextWindows: [String: Int], contextUsage: ContextUsage?) {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            return ([], [:], nil)
        }

        var modelContextWindows: [String: Int] = [:]
        var jsons: [[String: Any]] = []
        var lastUsed: Int?
        var lastWindow: Int?

        let resolver = Message2Resolver()
        for line in content.components(separatedBy: .newlines) {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = try? resolver.resolve(json) else {
                continue
            }
            jsons.append(json)

            let (used, window) = usageDelta(for: message, modelContextWindows: &modelContextWindows)
            if let u = used { lastUsed = u }
            if let w = window { lastWindow = w }
        }

        let contextUsage: ContextUsage? = {
            guard let used = lastUsed, let window = lastWindow, window > 0 else { return nil }
            return ContextUsage(used: used, window: window)
        }()

        return (jsons, modelContextWindows, contextUsage)
    }
}
