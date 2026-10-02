import Foundation

/// The 16-pt squircle at the head of every work line: a glyph for what the
/// work was, and a state drawn on the tile itself — never elsewhere on the
/// row (design/transcript/README.md "Tile").
nonisolated struct Tile: Sendable, Equatable {
    enum Glyph: Sendable, Equatable {
        /// One of the fifteen kinds of tool call.
        case tool(ToolKind)
        /// A workflow run — the sidebar's workflow glyph.
        case workflow
        /// A monitor's event — `waveform.path.ecg`.
        case monitor
        /// A question put to the reader — `questionmark.bubble`.
        case question
        /// A plan put to the reader for approval.
        case plan
        /// A picture pasted into a prompt — `photo`.
        case image
    }

    enum State: Sendable, Equatable {
        case done
        /// The call's input is still streaming: the glyph at half ink.
        case preparing
        /// A travelling arc, a third of the outline, once a second.
        case running
        /// The outline dashed, turning once every four seconds.
        case background
        /// Stopped until the reader decides: a coral outline, still.
        case waiting
        /// Red fill at 16 %, `!` in red.
        case failed
        /// Denied or interrupted: the glyph replaced by a stop square.
        case stopped
    }

    var glyph: Glyph
    var state: State
}

nonisolated extension Tile {
    /// The tile of one item's calls: the glyph of its first call's kind, the
    /// state of its last.
    init(calls: [ToolCall]) {
        self.init(glyph: .tool(calls[0].kind), state: State(calls[calls.count - 1].state))
    }
}

nonisolated extension Tile.State {
    /// How a call's state is drawn on its tile.
    init(_ state: ToolCallState) {
        switch state {
        case .preparing: self = .preparing
        case .waiting: self = .waiting
        case .running: self = .running
        case .background: self = .background
        case .done: self = .done
        case .failed: self = .failed
        case .denied, .interrupted: self = .stopped
        }
    }
}
