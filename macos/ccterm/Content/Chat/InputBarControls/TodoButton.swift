import SwiftUI

/// Trigger button rendered in the input-bar chrome row alongside
/// `BackgroundTaskButton`. Hidden until the session has at least one
/// todo on its plan; once present the button stays mounted so the user
/// can review the (now mostly completed) list. Opens a popover styled
/// as a memo / sticky-note: leading status circle, grouped by
/// active / completed, completed rows visually dimmed.
struct TodoButton: View {

    let session: Session
    @State private var isPresented = false

    var body: some View {
        let todos = session.todos
        if !todos.isEmpty {
            BarChromeButton(label: {
                HStack(spacing: 6) {
                    leadingIcon(forTodos: todos)
                    Text(buttonLabel(todos: todos))
                        .foregroundStyle(.primary)
                }
            }) {
                isPresented.toggle()
            }
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                TodoList(session: session)
            }
            .accessibilityLabel(accessibilityLabel(todos: todos))
        }
    }

    /// Visual cue mirroring the row leading glyph at button scale —
    /// an empty ring while at least one todo is still active, a
    /// filled ring once every item is completed. Sits at the same
    /// 6pt size as `BackgroundTaskButton`'s status dot so the chrome
    /// row reads as a single rhythm of small status badges.
    private func leadingIcon(forTodos todos: [TodoEntry]) -> some View {
        let hasActive = todos.contains { $0.status != .completed }
        return TodoStatusGlyph(status: hasActive ? .pending : .completed)
            .frame(width: 10, height: 10)
    }

    private func buttonLabel(todos: [TodoEntry]) -> String {
        let active = todos.filter { $0.status != .completed }.count
        if active > 0 {
            return String(localized: "\(active) of \(todos.count)")
        }
        return String(localized: "\(todos.count) done")
    }

    private func accessibilityLabel(todos: [TodoEntry]) -> String {
        let active = todos.filter { $0.status != .completed }.count
        if active > 0 {
            return String(localized: "\(active) active todos, \(todos.count) total")
        }
        return String(localized: "\(todos.count) completed todos")
    }
}
