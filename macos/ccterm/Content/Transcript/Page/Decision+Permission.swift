import AgentSDK
import Foundation

extension Decision {
    /// What the CLI is told for `request`: allow or deny; *always allow* with
    /// the request's suggested rule added; a plan approved or sent back; a
    /// question allowed with its answers written into the tool's input
    /// (`updatedInput`), as the CLI reads them back.
    func permissionDecision(for request: PermissionRequest) -> PermissionDecision {
        // TODO(live): every case, tested without AppKit.
        switch self {
        case .deny, .keepPlanning: .deny(message: "")
        default: .allow()
        }
    }
}
