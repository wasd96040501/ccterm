import Foundation

/// Per-mutation imperative signal. `SessionRuntime` synchronously emits one
/// `MessagesChange` at every site that writes `messages`, describing **what
/// just happened** (not "what the current state is").
///
/// Intent: the view bridge does not need to scan the whole messages table to
/// diff — it translates each case directly into
/// `Transcript2Controller.apply(.insert / .remove / .update)` or
/// `setHistory(...)`.
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
    /// Replace the view-side timeline wholesale (`loadHistory` Phase A
    /// completion / second entry into `.loaded`). `precomputedBlocks`
    /// is an optional `entryId → [Block]` map that the producer built
    /// off the main actor — when present, the bridge consumes these
    /// directly and skips the on-main Markdown parse in
    /// `MessageEntryBlockBuilder.entryBlocks`. When `nil`, the bridge
    /// falls back to building blocks inline.
    case reset([MessageEntry], precomputedBlocks: [UUID: [Block]]?)
    /// Append one new entry at the tail.
    case appended(MessageEntry)
    /// Prepend a group of entries at the head (`loadHistory` Phase B prefix).
    /// Same precomputed-blocks contract as `.reset`.
    case prepended([MessageEntry], precomputedBlocks: [UUID: [Block]]?)
    /// Replace one existing entry (tool_result merge / queued→confirmed /
    /// queued→failed / group items growing). `entry.id` is the view-side
    /// lookup key.
    case updated(MessageEntry)
    /// Remove one entry (`cancelMessage`). Full entry is passed through —
    /// the bridge derives the cached block ids from the entry's content,
    /// avoiding a reverse map.
    case removed(MessageEntry)
}
