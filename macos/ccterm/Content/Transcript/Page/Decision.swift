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
    /// A question's answers, the chosen labels by question.
    case answer([String: String])
}
