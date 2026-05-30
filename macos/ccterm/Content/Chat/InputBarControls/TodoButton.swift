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

    /// Visual cue mirroring the row's leading glyph at button scale.
    /// Picks the most "live" state present so the button reflects
    /// what the user would actually find inside the popover:
    /// in_progress > pending > completed.
    ///
    /// 12pt is the smallest size where the completed glyph's ring and
    /// inner dot still read at the same visual weight — below that the
    /// thin ring stroke picks up enough antialiasing dilution that the
    /// dot looks denser. (Compared side-by-side in
    /// `TodoStatusGlyphSnapshotTests`.)
    private func leadingIcon(forTodos todos: [TodoEntry]) -> some View {
        let glyphStatus: TodoEntry.Status
        if todos.contains(where: { $0.status == .inProgress }) {
            glyphStatus = .inProgress
        } else if todos.contains(where: { $0.status == .pending }) {
            glyphStatus = .pending
        } else {
            glyphStatus = .completed
        }
        return TodoStatusGlyph(status: glyphStatus, muted: true)
            .frame(width: 12, height: 12)
    }

    /// Counts read as **完成 / 总数** — the standard "how much of the
    /// plan is done" reading. The fraction lives in the chrome row
    /// whether or not there's still work to do; once everything is
    /// done the figures collapse to N/N which still reads correctly.
    private func buttonLabel(todos: [TodoEntry]) -> String {
        let completed = todos.filter { $0.status == .completed }.count
        return String(localized: "\(completed) of \(todos.count)")
    }

    private func accessibilityLabel(todos: [TodoEntry]) -> String {
        let completed = todos.filter { $0.status == .completed }.count
        return String(localized: "\(completed) of \(todos.count) todos completed")
    }
}
