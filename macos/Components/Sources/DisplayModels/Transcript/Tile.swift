import Foundation

/// The 16-pt squircle at the head of every work line: a glyph for what the
/// work was, and a state drawn on the tile itself — never elsewhere on the
/// row (design/transcript/README.md "Tile").
public nonisolated struct Tile: Sendable, Equatable {
    public enum Glyph: Sendable, Equatable {
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

    public enum State: Sendable, Equatable {
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

    public var glyph: Glyph
    public var state: State

    public init(glyph: Glyph, state: State) {
        self.glyph = glyph
        self.state = state
    }
}
