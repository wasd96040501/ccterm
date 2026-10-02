import Foundation

/// The reader's answer to a call that stopped for them — a permission, a
/// plan, a question. Every control that answers one reports it the same way,
/// with the call's id (`PageRowViewDelegate.pageRowView(_:didDecide:forCall:)`), and the
/// transcript tab and the document beside it answer the same call.
nonisolated enum Decision: Sendable, Equatable {
    case allow
    case deny
    /// Allow, and keep allowing: `rule` as the CLI suggested it.
    case alwaysAllow(rule: String)
    case approvePlan
    case keepPlanning
    /// A question's answers, the chosen labels by question — a typed *Other*
    /// as typed — and the *Notes* written beside a previewed option, by question.
    case answer([String: String], notes: [String: String] = [:])
    /// *Chat About This*: a question put aside to talk it over. Answers nothing —
    /// the CLI is told what the reader wants to clarify, with the answers given
    /// so far — and the focus goes to the composer.
    case chatAbout(answers: [String: String])
}
