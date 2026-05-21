import SwiftUI

/// Popover body for the todo plan. Memo-style — soft notepad surface,
/// status glyph on the leading edge, todo text spanning the rest of
/// the row. Items render in **creation order** with no grouping: a
/// status flip dims the row in place without shifting any other row
/// up or down, so the eye doesn't lose its place between updates.
///
/// Sizing — 340pt wide (slightly tighter than the task popover so
/// long subjects stay readable on two lines), content height capped
/// at 480pt with the inner ScrollView taking over past the cap.
struct TodoList: View {

    let session: Session

    private let popoverWidth: CGFloat = 340
    private let popoverMaxHeight: CGFloat = 480

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(session.todos) { todo in
                    TodoRow(todo: todo)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: popoverWidth)
        .frame(maxHeight: popoverMaxHeight)
    }
}

/// One memo line. Leading status glyph + the todo's display text.
/// Completed rows render at secondary text weight + a strikethrough
/// so the row stays in place but reads as finished work; the glyph
/// keeps the same outer size across states so the row's leading
/// edge doesn't jitter on a flip.
struct TodoRow: View {

    let todo: TodoEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TodoStatusGlyph(status: todo.status)
                .frame(width: 14, height: 14)
                // Pull the glyph down a smidge so it visually centers
                // against the cap-height of the first line of text.
                // (firstTextBaseline alignment puts the glyph at the
                // baseline, which sits below the visual middle.)
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                Text(displayText)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(isCompleted ? Color.secondary : Color.primary)
                    .strikethrough(isCompleted, color: Color.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                // Description renders for every state when present —
                // hiding it on completion would collapse a two-line
                // row to one and shift every neighbor up. When
                // completed, the description is also dimmed (already
                // .secondary) so the whole row reads as finished.
                if let detail = todo.description, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(isCompleted ? Color.secondary.opacity(0.6) : Color.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var isCompleted: Bool { todo.status == .completed }

    /// `activeForm` reads as a live verb when the assistant is mid-task
    /// ("Running tests"); falls back to `subject` for pending /
    /// completed rows where the imperative title is the natural fit.
    private var displayText: String {
        if todo.status == .inProgress,
            let active = todo.activeForm,
            !active.isEmpty
        {
            return active
        }
        return todo.subject
    }

    private var accessibilityLabel: String {
        let prefix: String
        switch todo.status {
        case .pending: prefix = String(localized: "Pending")
        case .inProgress: prefix = String(localized: "In progress")
        case .completed: prefix = String(localized: "Completed")
        }
        return "\(prefix): \(displayText)"
    }
}
