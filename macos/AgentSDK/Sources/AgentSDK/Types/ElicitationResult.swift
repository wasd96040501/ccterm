import Foundation

/// Response to an elicitation request.
public enum ElicitationResult {
    case respond(data: [String: Any])
    case cancel
}
