import AgentSDK
import Foundation

/// Why a session's CLI is not running when it should be — it exited non-zero,
/// or never launched. What the composer's failure section says (design 08
/// *Failed*): *Claude quit unexpectedly* over the detail, with Show Log and
/// Restart.
nonisolated struct SessionFailure: Sendable, Equatable {
    /// The words: *Exit code 1*, or the launch error.
    var reason: String
    /// stderr's last line, when the CLI wrote one — the composer sets it in
    /// the monospaced face, as the CLI's own output.
    var output: String?
    /// Everything the CLI wrote to stderr, for Show Log; empty when it never ran.
    var log: String

    /// The detail line: *Exit code 1 · <stderr's last line>*, or the reason alone.
    var message: String { output.map { "\(reason) · \($0)" } ?? reason }

    init(reason: String, output: String? = nil, log: String = "") {
        self.reason = reason
        self.output = output
        self.log = log
    }

    init(message: String, log: String = "") {
        self.init(reason: message, log: log)
    }

    /// The CLI exited without being asked to.
    init(_ termination: Termination) {
        let code = String(localized: "Exit code \(Int(termination.exitCode))")
        let last = termination.stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        self.init(reason: code, output: last, log: termination.stderr)
    }

    /// The launch did not get as far as a process: the error in words.
    init(launchError error: Error) {
        if case AgentSDKError.launchFailed(let reason) = error {
            self.init(message: reason)
        } else {
            self.init(message: error.localizedDescription)
        }
    }
}

extension SessionSettings {
    /// The settings a session at rest last ran on, read back from its
    /// transcript — the last assistant entry's `model` and `effort`, the last
    /// user entry's `permissionMode` — and mapped onto the account whose
    /// catalog has that model (the subscription when none does). A resume
    /// passes them, so it doesn't drift to the CLI's default model. A last mode
    /// of Bypass becomes Ask when `allowsBypassPermissions` is off. `nil` for a
    /// transcript with no assistant entry, or while no account is known to put
    /// the model on.
    nonisolated init?(lastOf transcript: Transcript, catalog: ModelCatalog, allowsBypassPermissions: Bool) {
        var model: String?
        var effort: Effort?
        var mode: PermissionMode?
        for message in transcript.messages.reversed() {
            switch message {
            case .assistant(let assistant) where model == nil:
                // The CLI's own notices (an API error, a command's output) ran no model.
                guard assistant.parentToolUseID == nil, assistant.model != "<synthetic>", !assistant.model.isEmpty
                else { continue }
                model = assistant.model
                effort = assistant.effort
            case .user(let user) where mode == nil:
                if user.parentToolUseID == nil, let recorded = user.permissionMode { mode = recorded }
            default:
                break
            }
            if model != nil, mode != nil { break }
        }
        guard let model, let choice = catalog.choice(forModelNamed: model) else { return nil }
        var permissionMode = mode ?? .default
        if permissionMode == .bypassPermissions, !allowsBypassPermissions { permissionMode = .default }
        self.init(model: choice, effort: effort, permissionMode: permissionMode, fastMode: false)
    }
}
