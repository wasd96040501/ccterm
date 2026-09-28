import AgentSDK
import Foundation

extension PermissionRequest {
    /// A request nobody answers, for previews, demos and tests.
    static func preview(id: String, toolName: String, input: JSONValue) -> PermissionRequest {
        PermissionRequest(id: id, toolName: toolName, input: input, onRespond: { _ in })
    }
}
