import Foundation

/// A prompt to send with ``Session/send(_:)``.
public struct UserInput: Sendable, Equatable {
    /// When a prompt sent mid-turn is handled.
    public enum Priority: String, Sendable {
        /// Abort the running turn and handle this prompt next.
        case now
        /// Fold into the running turn between tool calls (the CLI default).
        case next
        /// Wait until the running turn ends.
        case later
    }

    /// Identifies the prompt across its echo (``UserMessage/uuid``), its
    /// ``CommandLifecycle`` and ``ResultMessage/userMessageUUIDs``. The CLI
    /// skips a prompt whose uuid it has already seen.
    public var uuid: String
    public var content: [ContentBlock]
    /// `nil` uses the CLI default (``Priority/next``).
    public var priority: Priority?
    /// A plan to implement in a fresh context (the "clear context and
    /// implement plan" flow).
    public var planContent: String?

    public init(
        uuid: String = UUID().uuidString.lowercased(), content: [ContentBlock], priority: Priority? = nil,
        planContent: String? = nil
    ) {
        self.uuid = uuid
        self.content = content
        self.priority = priority
        self.planContent = planContent
    }

    /// A plain-text prompt.
    public init(_ text: String, uuid: String = UUID().uuidString.lowercased(), priority: Priority? = nil) {
        self.init(uuid: uuid, content: [.text(text)], priority: priority)
    }
}

extension UserInput {
    /// The stdin line for this prompt.
    var jsonValue: JSONValue {
        var o: [String: JSONValue] = [
            "type": "user",
            "message": ["role": "user", "content": .array(content.map(\.jsonValue))],
            "parent_tool_use_id": .null,
            "uuid": .string(uuid),
        ]
        if let priority { o["priority"] = .string(priority.rawValue) }
        if let planContent { o["plan_content"] = .string(planContent) }
        return .object(o)
    }
}
