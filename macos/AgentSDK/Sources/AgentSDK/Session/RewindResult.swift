import Foundation

/// The CLI's answer to ``Session/rewindConversation(to:)``.
public struct RewindResult: Sendable, Equatable {
    /// Whether the conversation was taken back.
    public var rewound: Bool
    /// Why it was not, as the CLI names it: `turn_running` while the turn
    /// it just reported is still winding down.
    public var reason: String?

    public init(rewound: Bool, reason: String? = nil) {
        self.rewound = rewound
        self.reason = reason
    }
}
