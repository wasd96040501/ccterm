import Foundation

/// Main-thread stall detector.
///
/// A background queue probes main-thread responsiveness every 50ms: schedules a
/// "tick" on the main thread and measures the delta between dispatch time and
/// when the tick actually runs. Logs a warning when it exceeds the threshold
/// (default 100ms). During real main-thread hangs (scrolling, layout) you'll
/// see `main stalled Xms` repeating in the log.
///
/// Usage: call `MainThreadWatchdog.start()` once at app launch; no lifecycle
/// management needed.
enum MainThreadWatchdog {

    private static let queue = DispatchQueue(label: "main-thread-watchdog", qos: .utility)
    private static var timer: DispatchSourceTimer?

    /// Idempotent — repeat calls only start one timer.
    ///
    /// - Parameter threshold: Report when stall exceeds this many seconds.
    ///   Default 0.1s (6 frames @60Hz).
    static func start(threshold: TimeInterval = 0.1) {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(50))
        t.setEventHandler { probe(threshold: threshold) }
        t.resume()
        timer = t
    }

    /// Dispatch a tick to the main thread; the background queue waits and
    /// measures latency. `sync` blocks the background thread itself so
    /// concurrent ticks don't trample each other.
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
