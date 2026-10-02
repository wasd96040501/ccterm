import Foundation

/// A response as it streams (``SessionConfiguration/includePartialMessages``):
/// every block of it so far, the last one possibly unfinished. Each finished
/// block still arrives as its own ``AssistantMessage``; a host keeping both
/// drops a block from the streaming one when its finished message arrives.
extension AssistantMessage {
    /// The empty response `event` begins (`messageStart`); `nil` for any
    /// other event.
    public init?(streamStart event: StreamEvent) {
        guard case .messageStart(let messageID, let model, _) = event.event else { return nil }
        self.init(
            uuid: event.uuid, sessionID: event.sessionID, messageID: messageID, model: model, content: [],
            parentToolUseID: event.parentToolUseID)
    }

    /// Folds the next event of this response: a block starts empty, text and
    /// thinking deltas extend the last block, a stop changes nothing. A tool
    /// call keeps the empty input it started with — its input fragments are
    /// ignored, so a call shows as preparing until its finished block lands.
    /// Events of another response (``StreamEvent/parentToolUseID`` or a
    /// different `messageStart`) are not this one's to fold; the caller
    /// starts a new message for them.
    public mutating func apply(_ event: StreamEvent) {
        switch event.event {
        case .contentBlockStart(_, let block):
            content.append(block)
        case .contentBlockDelta(_, .text(let text)):
            guard case .text(let soFar)? = content.last else { return }
            content[content.count - 1] = .text(soFar + text)
        case .contentBlockDelta(_, .thinking(let text)):
            guard case .thinking(let soFar)? = content.last else { return }
            content[content.count - 1] = .thinking(soFar + text)
        default:
            break
        }
    }
}
