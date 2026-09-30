import Foundation

/// Consecutive tool calls with nothing visible between them: one row
/// (design/transcript/01-run.md).
nonisolated struct ToolRun: Sendable, Equatable, Identifiable {
    /// The first call's id.
    let id: String
    /// Never empty.
    var items: [RunItem]
    /// The collapsed row. For a run of one item, that item named on its own
    /// rather than counted.
    var line: WorkLine

    /// A run of one opens its item with one click and has nothing to expand.
    var isSingle: Bool { items.count == 1 }

    /// The call stopped on a permission request, whose approval card the row
    /// shows under it.
    var waitingCall: ToolCall? {
        items.lazy.flatMap(\.calls).first { if case .waiting = $0.state { true } else { false } }
    }
}
