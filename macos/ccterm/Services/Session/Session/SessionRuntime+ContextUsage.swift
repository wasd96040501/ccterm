import AgentSDK
import Foundation

// MARK: - Context-window usage

extension SessionRuntime {

    /// Refreshes the cached context-window breakdown from the live CLI; see
    /// `ContextUsageCache.requestContextUsage`. Without a CLI there is
    /// nothing to ask and the cache is left as-is.
    @discardableResult
    func requestContextUsage(timeout: TimeInterval = 3.0) -> Task<Void, Never>? {
        guard let cliClient else { return nil }
        return contextUsageCache.requestContextUsage(cliClient: cliClient, timeout: timeout)
    }
}
