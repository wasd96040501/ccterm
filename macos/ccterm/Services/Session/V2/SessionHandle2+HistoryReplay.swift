import Foundation

/// 历史消息懒加载。
///
/// inactive 会话首次展示时调用 loadHistoryIfNeeded，后台读取 JSONL，
/// 逐条原始消息转发给 bridge，React 自行过滤和渲染。
extension SessionHandle2 {

    /// 懒加载历史消息到 bridge。已加载则立即回调。
    /// 调用方：SessionService 或 UI 层（首次展示 inactive 会话时）。
    func loadHistoryIfNeeded(completion: (() -> Void)? = nil) {
        fatalError("TODO")
    }
}
