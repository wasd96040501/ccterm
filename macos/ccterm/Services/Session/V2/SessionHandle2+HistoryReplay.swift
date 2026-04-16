import Foundation
import AgentSDK

/// 历史消息懒加载。后台读取 JSONL，过滤后将 raw JSON 批量发送到 bridge。
///
/// V2 的路径与 V1 对等：使用 MessageFilter 同时提取 contextUsage 和决定转发。
/// 未来 React 接管渲染过滤后，Swift 侧只需提取状态，不再做 shouldForward 判断。
extension SessionHandle2 {

    /// 懒加载历史消息。已加载则立即回调。
    /// - Parameters:
    ///   - jsonlFileURL: JSONL 文件路径（由调用方提供，一般来自 SessionRecord.slug）。
    ///     为 nil 或文件不存在时视为空历史，直接进入 .loaded 状态。
    ///   - completion: 加载并推送完成后在主线程回调。
    func loadHistoryIfNeeded(
        jsonlFileURL: URL?,
        completion: (() -> Void)? = nil
    ) {
        guard historyLoadState == .notLoaded else {
            completion?()
            return
        }
        historyLoadState = .loading

        Task.detached { [sessionId] in
            let (jsons, finalState) = Self.replayJSONL(from: jsonlFileURL)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.filterState = finalState
                if let snapshot = finalState.contextUsageSnapshot {
                    self.contextUsage = ContextUsage(
                        used: snapshot.usedTokens,
                        window: snapshot.windowTokens
                    )
                }
                self.bridge?.setRawMessages(conversationId: sessionId, messagesJSON: jsons)
                self.historyLoadState = .loaded
                completion?()
            }
        }
    }

    /// 后台安全的 JSONL 回放：解析 → 过滤 → 返回 raw JSON 数组与最终 filterState。
    nonisolated static func replayJSONL(
        from fileURL: URL?
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
