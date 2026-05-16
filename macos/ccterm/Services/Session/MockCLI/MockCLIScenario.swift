#if DEBUG

import Foundation

/// Minimal contract for a mock claude CLI behavior script used by UI tests.
///
/// **Most scenarios should subclass `MockCLIBaseScenario` instead of
/// implementing this protocol directly** — the base provides "close to the
/// real claude CLI" defaults (initialize ack, interrupt ack, user echo +
/// result success, ...) and scenarios override only the hooks that differ.
/// Implement this protocol directly only when you need fully custom routing
/// or want to skip the default parse (e.g. a chaos test reading raw JSON and
/// emitting at random).
///
/// The protocol layer intentionally provides no default behavior — all "what
/// mock claude should do" is **test-specific** and lives in scenario classes.
/// `MockCLIRunner` / `MockCLISender` / `MockCLIIncoming.parse` are scaffolding
/// only.
///
/// Registration: every scenario must be added to `MockCLIRegistry.scenarios`
/// with a name matching the UI test's
/// `launchEnvironment["CCTERM_MOCK_CLI_SCENARIO"]` value.
protocol MockCLIScenario: AnyObject {

    /// Called once when the subprocess starts, before any stdin message.
    /// Most scenarios do nothing here and wait for the host's `initialize`
    /// control_request; special cases (e.g. emitting a "process died early"
    /// signal) can act here.
    func onStart(send: MockCLISender)

    /// Called for each JSON line received from the host. `message` is a
    /// pre-parsed common shape; the `.unknown` path lets scenarios read `raw`
    /// directly.
    func onIncoming(_ message: MockCLIIncoming, send: MockCLISender)
}

extension MockCLIScenario {
    func onStart(send: MockCLISender) {}
}

#endif
