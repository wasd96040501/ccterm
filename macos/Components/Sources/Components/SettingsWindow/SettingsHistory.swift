import Foundation

/// The panes visited, by index, for back and forward — System Settings'
/// history.
struct SettingsHistory: Equatable {
    private(set) var current: Int
    private var back: [Int] = []
    private var forward: [Int] = []

    init(_ pane: Int) {
        current = pane
    }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// Moves to `pane`, dropping the forward list; staying put records nothing.
    mutating func go(to pane: Int) {
        guard pane != current else { return }
        back.append(current)
        forward.removeAll()
        current = pane
    }

    mutating func goBack() {
        guard let pane = back.popLast() else { return }
        forward.append(current)
        current = pane
    }

    mutating func goForward() {
        guard let pane = forward.popLast() else { return }
        back.append(current)
        current = pane
    }
}
