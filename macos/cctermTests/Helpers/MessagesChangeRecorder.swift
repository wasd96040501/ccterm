import Foundation

@testable import ccterm

/// `@MainActor` sink that captures every `MessagesChange` a handle emits.
/// Tests read `events` to assert on the order, type, and precomputed-blocks
/// payload of bridge instructions.
@MainActor
final class MessagesChangeRecorder {
    private(set) var events: [MessagesChange] = []

    func attach(to handle: SessionRuntime) {
        handle.onMessagesChange = { [weak self] change in
            self?.events.append(change)
        }
    }

    /// Wait until `predicate(events)` is true or `timeout` elapses. Polls
    /// on the main runloop — safe because the recorder is `@MainActor` and
    /// `SessionRuntime`'s `MainActor.run` hops interleave with this poll.
    func wait(
        timeout: TimeInterval = 5,
        until predicate: ([MessagesChange]) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(events) {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }
        return true
    }
}
