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
/// it must stay a class: `requestContextUsage`'s completion writes
/// `contextUsage` / `contextUsageFetchedAt` / `isFetchingContextUsage`
/// from an **async `[weak self]` `@MainActor` callback** that lands one
/// or more runloop ticks later. A value type captured by the closure
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

    /// True while a `getContextUsage` request is in flight. Lets the
    /// popover show a spinner instead of stale numbers during a refresh.
    internal(set) var isFetchingContextUsage: Bool = false

    /// Completions queued while a `getContextUsage` is in flight. All
    /// fire with the same outcome when the in-flight request settles.
    @ObservationIgnored private var contextUsagePendingCallbacks: [(ContextUsageOutcome) -> Void] = []

    /// @MainActor class deinit would otherwise route through
    /// `swift_task_deinitOnExecutorImpl`, hitting a macOS 26 SDK bug in
    /// libswift_Concurrency. nonisolated deinit skips the executor-hop
    /// path and avoids the bug (mirrors `SessionRuntime`).
    nonisolated deinit {}

    /// Fire-and-forget request for a `get_context_usage` breakdown.
    ///
    /// - The result is cached on `self.contextUsage` (+ `fetchedAt`) so
    ///   the popover can re-open synchronously between refreshes.
    /// - Concurrent calls are coalesced: while `isFetchingContextUsage`
    ///   is true, additional callers attach their completion to the
    ///   pending request rather than firing a new one.
    /// - Old CLIs never respond; the SDK times out into `.unsupported`
    ///   after `timeout` seconds, the cache is left as-is, and
    ///   `isFetchingContextUsage` flips back to false.
    /// - Completion is invoked on the main actor exactly once.
    ///
    /// The `cliClient` is passed in by the runtime's thin forwarder — the
    /// cache stays agnostic of how the CLI is bound.
    func requestContextUsage(
        cliClient: any CLIClient,
        timeout: TimeInterval = 3.0,
        completion: ((ContextUsageOutcome) -> Void)? = nil
    ) {
        if let completion {
            contextUsagePendingCallbacks.append(completion)
        }
        guard !isFetchingContextUsage else { return }
        isFetchingContextUsage = true

        cliClient.getContextUsage(timeout: timeout) { [weak self] outcome in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .usage(let usage) = outcome {
                    self.contextUsage = usage
                    self.contextUsageFetchedAt = Date()
                }
                self.isFetchingContextUsage = false
                let callbacks = self.contextUsagePendingCallbacks
                self.contextUsagePendingCallbacks.removeAll()
                for cb in callbacks { cb(outcome) }
            }
        }
    }
}
