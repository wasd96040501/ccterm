import AgentSDK
import Foundation

// MARK: - Context-window usage

extension SessionRuntime {

    /// Fire-and-forget request for a `get_context_usage` breakdown.
    ///
    /// Thin forwarder: the runtime owns the bound `cliClient`, so it
    /// resolves it here and hands it to `contextUsageCache`, which owns
    /// the cache fields + coalescing + async completion. `.unsupported`
    /// is delivered immediately when there is no live CLI.
    func requestContextUsage(
        timeout: TimeInterval = 3.0,
        completion: ((ContextUsageOutcome) -> Void)? = nil
    ) {
        guard let cliClient else {
            completion?(.unsupported)
            return
        }
        contextUsageCache.requestContextUsage(
            cliClient: cliClient, timeout: timeout, completion: completion)
    }
}
