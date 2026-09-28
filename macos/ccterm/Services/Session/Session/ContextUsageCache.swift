import AgentSDK
import Foundation
import Observation

// MARK: - Context-window usage cache

/// Cached `get_context_usage` breakdown for one session, projected off
/// the CLI's fire-and-forget context-usage request.
///
/// This is a **reference-type `@Observable` projection** owned by
/// `SessionRuntime` (`runtime.contextUsageCache`). Even though the three
/// fields are whole-value assignments (not in-place collection mutation),
/// it must stay a class: `requestContextUsage`'s refresh task writes
/// `contextUsage` / `contextUsageFetchedAt` / `isFetchingContextUsage`
/// one or more runloop ticks later. A value type captured by the closure
/// would write a copy that observation never sees — the
/// `ContextRingButton` popover would never refresh. The reference type
/// keeps the write on the observed instance so SwiftUI readers tracking
/// `session.contextUsage` → `runtime.contextUsageCache.contextUsage`
/// re-render when the response lands.
@Observable
@MainActor
final class ContextUsageCache {

    /// Most-recent typed `get_context_usage` response from the CLI. `nil`
    /// until the popover has fetched at least once. The popover reads
    /// this directly so the panel can render synchronously on re-open;
    /// the request is fired-and-forgotten by the UI when the user opens
    /// the popover.
    internal(set) var contextUsage: ContextUsage?

    /// When the cached `contextUsage` was last refreshed.
    internal(set) var contextUsageFetchedAt: Date?

    /// True while a refresh is in flight. Lets the
    /// popover show a spinner instead of stale numbers during a refresh.
    internal(set) var isFetchingContextUsage: Bool = false

    /// The in-flight refresh; concurrent requests join it.
    @ObservationIgnored private var refresh: Task<Void, Never>?

    /// @MainActor class deinit would otherwise route through
    /// `swift_task_deinitOnExecutorImpl`, hitting a macOS 26 SDK bug in
    /// libswift_Concurrency. nonisolated deinit skips the executor-hop
    /// path and avoids the bug (mirrors `SessionRuntime`).
    nonisolated deinit {}

    /// Refreshes `contextUsage` from the CLI.
    ///
    /// - The result is cached (+ `fetchedAt`) so the popover can re-open
    ///   synchronously between refreshes.
    /// - Concurrent calls join the in-flight refresh instead of sending
    ///   another request.
    /// - A CLI that doesn't answer within `timeout` (one without the
    ///   request) leaves the cache as-is; so does an error.
    ///
    /// Returns the refresh so a caller can await it; the UI ignores it.
    @discardableResult
    func requestContextUsage(cliClient: any CLIClient, timeout: TimeInterval = 3.0) -> Task<Void, Never> {
        if let refresh { return refresh }
        isFetchingContextUsage = true
        let task = Task { [weak self] in
            let request = Task { try await cliClient.contextUsage() }
            let timer = Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                request.cancel()
            }
            let usage = try? await request.value
            timer.cancel()
            guard let self else { return }
            if let usage {
                self.contextUsage = usage
                self.contextUsageFetchedAt = Date()
            }
            self.isFetchingContextUsage = false
            self.refresh = nil
        }
        refresh = task
        return task
    }
}
