#if DEBUG

import Foundation

/// Name → scenario factory lookup. UI tests select a scenario via the
/// environment variable `CCTERM_MOCK_CLI_SCENARIO=<name>`.
///
/// To add a scenario, add an entry to `scenarios`. **This is the only entry
/// point tests see** — unregistered scenarios cannot be used.
enum MockCLIRegistry {

    /// Scenario name → zero-arg factory. Name must match the UI test's
    /// environment variable value.
    static let scenarios: [String: () -> any MockCLIScenario] = [
        "hangingTurn": { HangingTurnScenario() }
    ]

    /// Returns nil for unknown names; `MockCLIRunner` writes stderr and exits
    /// non-zero, and `SessionHandle2`'s launch-failure path surfaces it to
    /// UI/test.
    static func scenario(named name: String) -> (any MockCLIScenario)? {
        scenarios[name]?()
    }
}

#endif
