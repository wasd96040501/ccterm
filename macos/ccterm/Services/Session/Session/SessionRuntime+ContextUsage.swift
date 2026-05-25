import AgentSDK
import Foundation

// MARK: - Context-window usage

extension SessionRuntime {

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
    func requestContextUsage(
        timeout: TimeInterval = 3.0,
        completion: ((ContextUsageOutcome) -> Void)? = nil
    ) {
        guard let cliClient else {
            completion?(.unsupported)
            return
        }
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
