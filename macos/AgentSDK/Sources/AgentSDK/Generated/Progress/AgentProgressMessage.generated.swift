import Foundation

public enum AgentProgressMessage: JSONParseable, UnknownStrippable {
    case assistant(MessageAssistant)
    case user(MessageUser)
    case unknown(name: String, raw: [String: Any])
}
