import SwiftUI

/// Popover body for the todo plan. Memo-style — soft notepad surface,
/// status glyph on the leading edge, todo text spanning the rest of
/// the row. Two groups: **Active** (pending + in_progress) and
/// **Completed** (de-emphasized so the eye lands on what's still
/// open). No detail sheet — the row is the surface.
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
            VStack(alignment: .leading, spacing: 14) {
                let groups = Self.group(todos: session.todos)
                ForEach(groups) { group in
                    section(group)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: popoverWidth)
        .frame(maxHeight: popoverMaxHeight)
    }

    private func section(_ group: TodoGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(group.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(group.todos.count)")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 4)
            VStack(spacing: 2) {
                ForEach(group.todos) { todo in
                    TodoRow(todo: todo, dimmed: group.id == "completed")
                }
            }
        }
    }

    private struct TodoGroup: Identifiable {
        let id: String
        let title: String
        let todos: [TodoEntry]
    }

    private static func group(todos: [TodoEntry]) -> [TodoGroup] {
        // In-progress floats above pending inside the Active group —
        // the row the assistant is *currently* on should sit at the
        // top so the eye lands there first; pending items remain in
        // creation order beneath.
        let active = todos.filter { $0.status != .completed }
        let activeSorted = active.sorted { lhs, _ in lhs.status == .inProgress }
        let completed = todos.filter { $0.status == .completed }

        var out: [TodoGroup] = []
        if !activeSorted.isEmpty {
            out.append(
                TodoGroup(
                    id: "active",
                    title: String(localized: "To do"),
                    todos: activeSorted
                ))
        }
        if !completed.isEmpty {
            out.append(
                TodoGroup(
                    id: "completed",
                    title: String(localized: "Done"),
                    todos: completed
                ))
        }
        return out
    }
}

/// One memo line. Leading status glyph + the todo's display text.
/// `dimmed` is set for the Completed group so the whole row sits at
/// secondary text weight and the glyph fades — completed work stays
/// available for reference but doesn't compete with active items.
struct TodoRow: View {

    let todo: TodoEntry
    let dimmed: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TodoStatusGlyph(status: todo.status)
                .frame(width: 14, height: 14)
                .opacity(dimmed ? 0.55 : 1.0)
                // Pull the glyph down a smidge so it visually centers
                // against the cap-height of the first line of text.
                // (firstTextBaseline alignment puts the glyph at the
                // baseline, which sits below the visual middle.)
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                Text(displayText)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(dimmed ? Color.secondary : Color.primary)
                    .strikethrough(dimmed, color: Color.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = todo.description, !detail.isEmpty, !dimmed {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
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
