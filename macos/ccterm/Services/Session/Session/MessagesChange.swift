import Foundation

/// Per-mutation imperative signal. `SessionRuntime` synchronously emits one
/// `MessagesChange` at every site that writes `messages`, describing **what
/// just happened** (not "what the current state is").
///
/// Intent: the view bridge does not need to scan the whole messages table to
/// diff — it translates each case directly into
/// `Transcript2Controller.apply(.append / .replace / .update / .remove)`.
/// History load is **not** a `MessagesChange`: it flows through
/// `TranscriptBackfillPipeline` straight into `apply`, never the bridge.
///
/// Channel: the runtime exposes a synchronous closure
/// `onMessagesChange: ((MessagesChange) -> Void)?`. `Session.wireRuntimeMessagesSink`
/// installs a multiplex closure on that field at session creation /
/// promotion that calls `bridge.apply(change)` (always) then
/// `session.onMessagesChange?(change)` (optional external observer).
/// This is the AppKit renderer's only outgoing sink — firing
/// synchronously guarantees the mutation and `controller.apply`
/// happen in the same call stack, with no extra hop through
/// AsyncStream / @Observable. The SwiftUI renderer reads the runtime's
/// `@Observable` fields (`messages` / `status` / `isRunning` / ...) and
/// does not use this channel.
enum MessagesChange {
    /// Append one new entry at the tail.
    case appended(MessageEntry)
    /// Replace one existing entry (tool_result merge / queued→confirmed /
    /// queued→failed / group items growing). `entry.id` is the view-side
    /// lookup key.
    case updated(MessageEntry)
    /// Remove one entry (`cancelMessage`). Full entry is passed through —
    /// the bridge derives the cached block ids from the entry's content,
    /// avoiding a reverse map.
    case removed(MessageEntry)
}
