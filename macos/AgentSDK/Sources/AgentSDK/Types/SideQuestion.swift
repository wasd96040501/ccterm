import Foundation

// MARK: - SideQuestionAnswer

/// A `/btw`-style side question answer returned by the CLI.
///
/// The CLI answers a side question with a one-shot, tool-less model reply
/// that shares the conversation context but is never written to the
/// transcript and never advances the main turn loop. See
/// `Session.askSideQuestion`.
public struct SideQuestionAnswer: Equatable {
    /// The model's answer text.
    public let response: String
    /// `true` when the reply is *not* a genuine answer — the model tried to
    /// call a tool (side questions are tool-less) or the API errored, and the
    /// CLI wrapped that into a human-readable note instead. Callers may want
    /// to render these differently from a real answer.
    public let synthetic: Bool

    public init(response: String, synthetic: Bool) {
        self.response = response
        self.synthetic = synthetic
    }
}

// MARK: - SideQuestionOutcome

/// Result of `Session.askSideQuestion`.
public enum SideQuestionOutcome: Equatable {
    /// The CLI returned an answer (possibly `synthetic`).
    case answer(SideQuestionAnswer)
    /// The CLI responded successfully but produced no text (`response: null`).
    case empty
    /// No live CLI to ask — the session isn't running, or it's a draft.
    /// Delivered synchronously; treat it as "feature unavailable".
    case unsupported
    /// The CLI returned a `control_response` error (e.g. an older CLI that
    /// speaks the control protocol but lacks the `side_question` subtype),
    /// or the payload failed to parse.
    case sdkError(String)

    public var answer: SideQuestionAnswer? {
        if case .answer(let a) = self { return a }
        return nil
    }
}
