import AgentSDK
import Foundation

/// One recorded `/btw` exchange in a session's side-question thread.
struct SideQuestionTurn: Equatable {
    let question: String
    let response: String
}

// MARK: - Side question (/btw)

extension SessionRuntime {

    /// Upper bound on the retained `/btw` thread — matches the CLI's own
    /// overlay (`ac3 = 20`). Older turns drop off the front.
    static let sideQuestionThreadCap = 20

    /// Asks a `/btw`-style side question against the live conversation
    /// without disturbing the current turn.
    ///
    /// The CLI answers from the running session's own context with a
    /// separate, **tool-less**, one-shot model call that is **not** written
    /// to the transcript and does **not** advance the main turn loop — safe
    /// to fire while Claude is mid-work.
    ///
    /// **Consecutive questions are threaded client-side.** The CLI host
    /// answers each `side_question` statelessly (`threadHistory: false`) and
    /// the control request carries only the question string, so the host
    /// cannot link two side questions on its own (verified: plant a fact in
    /// #1, ask for it in #2 → the host replies "unknown"). To match the
    /// CLI's own `/btw`, prior real Q&A from `sideQuestionThread` is embedded
    /// into the question text here; the model then treats the thread as
    /// shared context. Real (non-synthetic) answers are recorded back.
    ///
    /// `.unsupported` when there is no live CLI; `.sdkError` when an older
    /// CLI rejects the subtype. `completion` runs on the main actor once.
    func askSideQuestion(
        _ question: String,
        completion: @escaping (SideQuestionOutcome) -> Void
    ) {
        guard let cliClient else {
            completion(.unsupported)
            return
        }
        cliClient.askSideQuestion(threadedQuestion(question)) { [weak self] outcome in
            Task { @MainActor in
                // Record the *original* question (not the embedded form) so
                // the next turn's context doesn't nest prior threads.
                if case .answer(let answer) = outcome, !answer.synthetic {
                    self?.recordSideQuestion(question: question, response: answer.response)
                }
                completion(outcome)
            }
        }
    }

    /// Forget this session's `/btw` thread so the next side question starts
    /// fresh (e.g. an explicit "clear" affordance, like the CLI overlay's
    /// `x` key).
    func clearSideQuestionThread() {
        sideQuestionThread.removeAll()
    }

    // MARK: - Private

    /// Embeds prior thread Q&A ahead of `question`. No-op for the first
    /// question in a thread.
    private func threadedQuestion(_ question: String) -> String {
        guard !sideQuestionThread.isEmpty else { return question }
        let prior =
            sideQuestionThread
            .map { "Q: \($0.question)\nA: \($0.response)" }
            .joined(separator: "\n\n")
        return """
            Earlier in this side-question thread (not part of the main conversation):
            \(prior)

            Now answer this follow-up:
            \(question)
            """
    }

    private func recordSideQuestion(question: String, response: String) {
        sideQuestionThread.append(SideQuestionTurn(question: question, response: response))
        let overflow = sideQuestionThread.count - Self.sideQuestionThreadCap
        if overflow > 0 { sideQuestionThread.removeFirst(overflow) }
    }
}
