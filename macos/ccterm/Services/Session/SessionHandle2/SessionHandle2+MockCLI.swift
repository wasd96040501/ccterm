#if DEBUG

import Foundation
import AgentSDK

/// CLI subprocess override used in UI test mode.
///
/// `AppState+TestMode` sets this when `CCTERM_TEST_MODE=1`;
/// `SessionHandle2.makeAgentConfig` detects non-nil and replaces `binaryPath`
/// (executable) and `env` (subprocess env vars) so the CLI actually spawns
/// the current ccterm binary into the mock path (see `AppEntryPoint`).
///
/// Process-wide — once set, it affects every subsequent
/// `SessionHandle2.ensureStarted`. UI tests are single-process, single-
/// scenario, so per-handle granularity is unnecessary.
struct MockCLIOverride {

    /// Passed straight to `SessionConfiguration.binaryPath`. Normally just
    /// `Bundle.main.executablePath!`.
    let binaryPath: String

    /// Passed straight to `SessionConfiguration.env`. Must contain at least
    /// `CCTERM_RUN_AS_MOCK_CLI=1` + `CCTERM_MOCK_CLI_SCENARIO=<name>`.
    let env: [String: String]
}

extension SessionHandle2 {

    /// Global switch. `nil` means production (real claude CLI); non-nil
    /// means UI test mode. Set once by `AppState+TestMode` at app startup
    /// and never touched again.
    @MainActor static var mockCLIOverride: MockCLIOverride?
}

#endif
