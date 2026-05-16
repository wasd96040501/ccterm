#if DEBUG

import Foundation

/// UI test mode wiring. Handshake with the XCUI test runner via environment
/// variables at app launch:
///
/// | Variable                       | Meaning                                          |
/// |--------------------------------|--------------------------------------------------|
/// | `CCTERM_TEST_MODE=1`           | Master switch — enables in-memory repo / mock CLI |
/// | `CCTERM_MOCK_CLI_SCENARIO=foo` | Scenario the mock CLI subprocess should run (see Registry) |
///
/// Effects:
/// 1. Switches `SessionManager2` to `InMemorySessionRepository` so test data
///    never lands in the real CoreData store.
/// 2. Sets `SessionHandle2.mockCLIOverride` with binary path + env so that
///    subsequent `ensureStarted`-spawned "CLI subprocesses" are actually the
///    current ccterm binary (taking the mock branch in `AppEntryPoint`,
///    running the requested scenario).
///
/// DEBUG only — this file is excluded from release builds.
extension AppState {

    /// Call early from `init`. Returns a test-mode `SessionManager2` (in-memory
    /// repo) when test mode is on; returns nil otherwise so the caller falls
    /// back to the regular path.
    static func applyTestModeIfNeeded() -> SessionManager2? {
        let env = ProcessInfo.processInfo.environment
        guard env["CCTERM_TEST_MODE"] == "1" else { return nil }

        let scenario = env["CCTERM_MOCK_CLI_SCENARIO"] ?? ""
        guard let executable = Bundle.main.executablePath else {
            // Missing executable path is virtually impossible, but fall back safely: skip mock CLI.
            return SessionManager2(repository: InMemorySessionRepository())
        }

        SessionHandle2.mockCLIOverride = MockCLIOverride(
            binaryPath: executable,
            env: [
                "CCTERM_RUN_AS_MOCK_CLI": "1",
                "CCTERM_MOCK_CLI_SCENARIO": scenario,
            ]
        )

        return SessionManager2(repository: InMemorySessionRepository())
    }
}

#endif
