import DisplayModels
import Foundation

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
