import DisplayModels
import Foundation

/// One line of an expanded run: a call, or consecutive edits to one file,
/// which the reader asks about as one change
/// (design/transcript/01-run.md "Expanded").
nonisolated struct RunItem: Sendable, Equatable, Identifiable {
    /// One call, or more than one edit to the same file, in order. Never empty.
    let calls: [ToolCall]
    /// The item as a list line.
    var line: WorkLine

    /// The first call's id: what the item opens beside, and where the
    /// transcript reveals it.
    var id: String { calls[0].id }

    var kind: ToolKind { calls[0].kind }

    /// Whether a click opens its document beside (`ToolCall.opensBeside`).
    var opensBeside: Bool { calls[0].opensBeside }

    /// How the item ended: its last call's state.
    var state: ToolCallState { calls[calls.count - 1].state }
}
