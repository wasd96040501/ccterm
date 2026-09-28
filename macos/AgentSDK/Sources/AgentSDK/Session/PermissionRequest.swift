import Foundation
import os

/// The CLI asks whether a tool call may run.
///
/// The tool waits, with no timeout, until you call ``respond(_:)``. If the
/// CLI withdraws the question first (the turn was interrupted), the session
/// emits ``SessionEvent/permissionRequestCancelled(id:)`` and a later
/// ``respond(_:)`` is ignored.
public final class PermissionRequest: Sendable, Identifiable {
    /// The CLI's request id; matches ``SessionEvent/permissionRequestCancelled(id:)``.
    public let id: String
    public let toolName: String
    public let toolUseID: String
    /// The tool call's input; see ``ToolUseBlock/input``.
    public let input: JSONValue
    /// Rule or mode changes the CLI proposes for "always allow".
    public let suggestions: [PermissionUpdate]
    /// Why the call needs approval, when the CLI says.
    public let decisionReason: String?
    /// What decided to ask: `"rule"`, `"mode"`, `"subcommandResults"` (a
    /// compound Bash command checked part by part), `"safetyCheck"`, …
    public let decisionReasonType: String?
    /// The path outside the allowed directories that triggered the request.
    public let blockedPath: String?
    /// The subagent asking; `nil` for the main thread.
    public let agentID: String?

    private let responder: OSAllocatedUnfairLock<(@Sendable (PermissionDecision) -> Void)?>

    /// A ``Session`` creates these for the CLI's questions; build one
    /// yourself to stand in for the CLI (previews, tests). `onRespond`
    /// receives the first ``respond(_:)``.
    public init(
        id: String = UUID().uuidString, toolName: String, toolUseID: String = "", input: JSONValue,
        suggestions: [PermissionUpdate] = [], decisionReason: String? = nil,
        decisionReasonType: String? = nil, blockedPath: String? = nil,
        agentID: String? = nil, onRespond: @escaping @Sendable (PermissionDecision) -> Void
    ) {
        self.id = id
        self.toolName = toolName
        self.toolUseID = toolUseID
        self.input = input
        self.suggestions = suggestions
        self.decisionReason = decisionReason
        self.decisionReasonType = decisionReasonType
        self.blockedPath = blockedPath
        self.agentID = agentID
        self.responder = OSAllocatedUnfairLock(initialState: onRespond)
    }

    /// Answers the request. Only the first call has an effect.
    public func respond(_ decision: PermissionDecision) {
        let responder = self.responder.withLock { current in
            defer { current = nil }
            return current
        }
        responder?(decision)
    }

    /// Whether the request still awaits an answer.
    public var isPending: Bool { responder.withLock { $0 != nil } }

    /// Drops the responder without answering (the CLI withdrew the request).
    func invalidate() {
        responder.withLock { $0 = nil }
    }
}
