import Foundation

/// A response as it streams (``SessionConfiguration/includePartialMessages``):
/// every block of it so far, the last one possibly unfinished. The finished
/// blocks still arrive as their own ``AssistantMessage``s, which replace it.
extension AssistantMessage {
    /// The empty response `event` begins (`messageStart`); `nil` for any
    /// other event.
    public init?(streamStart event: StreamEvent) {
        // TODO(live): messageStart → uuid / sessionID / parentToolUseID from
        // the event, messageID and model from its payload, no content.
        return nil
    }

    /// Folds the next event of this response: a block starts empty, text and
    /// thinking deltas extend the last block, a stop changes nothing. A tool
    /// call keeps the empty input it started with — its input fragments are
    /// ignored, so a call shows as preparing until its finished block lands.
    /// Events of another response (``StreamEvent/parentToolUseID`` or a
    /// different `messageStart`) are not this one's to fold; the caller
    /// starts a new message for them.
    public mutating func apply(_ event: StreamEvent) {
        // TODO(live): contentBlockStart / contentBlockDelta(.text, .thinking).
    }
}
