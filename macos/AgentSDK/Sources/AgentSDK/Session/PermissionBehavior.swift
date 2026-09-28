import Foundation

/// What a rule does to matching tool calls.
public enum PermissionBehavior: String, Sendable, Codable {
    case allow, deny, ask
}
