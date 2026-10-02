import AgentSDK
import Foundation

/// Why a session's CLI is not running when it should be — it exited non-zero,
/// or never launched. What the composer's failure section says (design 08
/// *Failed*): *Claude quit unexpectedly* over the detail, with Show Log and
/// Restart.
nonisolated struct SessionFailure: Sendable, Equatable {
    /// The detail line: *Exit code 1 · <stderr's last line>*, or the launch
    /// error in words.
    var message: String
    /// Everything the CLI wrote to stderr, for Show Log; empty when it never ran.
    var log: String

    init(message: String, log: String = "") {
        self.message = message
        self.log = log
    }

    /// The CLI exited without being asked to.
    init(_ termination: Termination) {
        // TODO(fill B): word it as the design's detail line (localized).
        self.init(message: termination.stderr, log: termination.stderr)
    }
}

extension SessionSettings {
    /// The settings a session at rest last ran on, read back from its
    /// transcript — the last assistant entry's `model` and `effort`, the last
    /// user entry's `permissionMode` — and mapped onto the account whose
    /// catalog has that model (the subscription when none does). A resume
    /// passes them, so it doesn't drift to the CLI's default model. A last mode
    /// of Bypass becomes Ask when `allowsBypassPermissions` is off. `nil` for a
    /// transcript with no assistant entry.
    nonisolated init?(lastOf transcript: Transcript, catalog: ModelCatalog, allowsBypassPermissions: Bool) {
        // TODO(fill B)
        return nil
    }
}
