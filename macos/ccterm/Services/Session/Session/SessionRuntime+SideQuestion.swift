import AgentSDK
import Foundation

// MARK: - Side question (/btw)

extension SessionRuntime {

    /// Asks a `/btw`-style side question against the live conversation
    /// without disturbing the current turn.
    ///
    /// The CLI answers from the running session's own context with a
    /// separate, **tool-less**, one-shot model call that is **not** written
    /// to the transcript and does **not** advance the main turn loop — so it
    /// is safe to fire while Claude is mid-work. This is a pure RPC: it
    /// touches no observable runtime state (no transcript entry, no
    /// `messages` mutation), matching the "local action" rule.
    ///
    /// `.unsupported` when there is no live CLI; `.sdkError` when an older
    /// CLI rejects the subtype. `completion` is invoked on the main actor
    /// once, when the CLI responds.
    func askSideQuestion(
        _ question: String,
        completion: @escaping (SideQuestionOutcome) -> Void
    ) {
        guard let cliClient else {
            completion(.unsupported)
            return
        }
        cliClient.askSideQuestion(question) { outcome in
            Task { @MainActor in completion(outcome) }
        }
    }
}
