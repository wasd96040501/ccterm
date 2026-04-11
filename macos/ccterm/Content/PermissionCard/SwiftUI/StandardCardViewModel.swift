import SwiftUI
import Observation
import AgentSDK

@Observable
final class StandardCardViewModel {
    let request: PermissionRequest
    let toolName: String
    let content: ToolContentDescriptor
    private let onDecision: (PermissionDecision) -> Void

    init(request: PermissionRequest, onDecision: @escaping (PermissionDecision) -> Void) {
        self.request = request
        self.toolName = request.toolName
        self.content = ToolContentDescriptor.from(request)
        self.onDecision = onDecision
    }

    /// Primary confirm action (also used by Cmd+Return).
    func confirm() { onDecision(request.allowOnce()) }

    func allowAlways() { onDecision(request.allowAlways()) }

    func deny(feedback: String? = nil) {
        if let feedback, !feedback.isEmpty {
            onDecision(request.deny(feedback: feedback))
        } else {
            onDecision(request.deny())
        }
    }
}
