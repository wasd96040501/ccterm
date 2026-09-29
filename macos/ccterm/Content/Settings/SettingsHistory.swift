import Foundation

/// The panes visited, for back and forward — System Settings' history.
struct SettingsHistory: Equatable {
    private(set) var current: SettingsPane
    private var back: [SettingsPane] = []
    private var forward: [SettingsPane] = []

    init(_ pane: SettingsPane) {
        current = pane
    }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// Moves to `pane`, dropping the forward list; staying put records nothing.
    mutating func go(to pane: SettingsPane) {
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
