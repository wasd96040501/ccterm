import Foundation

/// The fate of a prompt sent with ``Session/send(_:)``, keyed by its
/// ``UserInput/uuid``.
///
/// A prompt goes `queued` → `started` → one terminal state. For the prompt
/// that opened a turn, `completed` arrives after the turn's
/// ``ResultMessage``; for a prompt folded into a running turn it arrives
/// before.
public struct CommandLifecycle: Sendable, Equatable {
    public struct State: RawRepresentable, Hashable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let queued = State(rawValue: "queued")
        public static let started = State(rawValue: "started")
        public static let completed = State(rawValue: "completed")
        /// Interrupted, cancelled while queued, or its turn failed.
        public static let cancelled = State(rawValue: "cancelled")
        /// Dropped because the session ended.
        public static let discarded = State(rawValue: "discarded")
        /// Rejected by policy.
        public static let refused = State(rawValue: "refused")

        /// `true` once the prompt will make no further progress.
        public var isTerminal: Bool { self != .queued && self != .started }
    }

    public var commandUUID: String
    public var state: State
}

extension CommandLifecycle: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.commandUUID = try c.required(String.self, "command_uuid")
        self.state = State(rawValue: try c.required(String.self, "state"))
    }
}
