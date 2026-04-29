import Foundation

/// 主线程 stall 检测器。
///
/// 用后台队列每 50ms 探测一次主线程响应延迟:在主线程 schedule 一次 "tick",
/// 在后台线程记录派发时刻到 tick 真正执行的时刻之间的 delta。超过阈值(默认
/// 100ms)就打一条 warning。滚动/布局期间如果主线程真的被堵住,日志里会看到
/// `main stalled Xms` 连续冒出。
///
/// 用法:App 启动时调一次 `MainThreadWatchdog.start()`,不用自己管生命周期。
enum MainThreadWatchdog {

    private static let queue = DispatchQueue(label: "main-thread-watchdog", qos: .utility)
    private static var timer: DispatchSourceTimer?

    /// 启动检测。idempotent——重复调用只启动一次。
    ///
    /// - Parameter threshold: 超过此秒数才报。默认 0.1s(6 帧@60Hz)。
    static func start(threshold: TimeInterval = 0.1) {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(50))
        t.setEventHandler { probe(threshold: threshold) }
        t.resume()
        timer = t
    }

    /// 每次探测:在主线程派发一个 tick,后台等它完成并测延迟。
    /// 使用 sync 阻塞后台线程自身,避免并发 tick 互相踩。
    private static func probe(threshold: TimeInterval) {
        let dispatchedAt = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.sync {
            let delta = CFAbsoluteTimeGetCurrent() - dispatchedAt
            if delta >= threshold {
                appLog(.warning, "MainHang", "main stalled \(Int(delta * 1000))ms")
            }
        }
    }
}
