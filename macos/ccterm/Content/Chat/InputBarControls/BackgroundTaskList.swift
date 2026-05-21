import Combine
import SwiftUI

/// Popover body listing every background bash task on the session. Each
/// row is a trigger — clicking one presents `BackgroundTaskDetailSheet`
/// modally over the host window with the task's full command, summary,
/// and streaming output. The list itself stays compact: only the
/// title, status, and elapsed time live here. Anything bigger goes in
/// the sheet.
///
/// Sizing — 360pt wide, content height capped at 480pt with the inner
/// `ScrollView` taking over past the cap.
struct BackgroundTaskList: View {

    let session: Session
    /// Selection escape hatch — the popover surfaces a tap on a row by
    /// invoking this with the task id; the caller (`BackgroundTaskButton`)
    /// owns the detail sheet and decides when to dismiss the popover.
    let onSelectTask: (String) -> Void

    /// Tick on a 1s timer while the popover is open so rows re-render
    /// their elapsed-time counters. The runtime would otherwise only
    /// publish on task state transitions and the counter would freeze.
    @State private var now: Date = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let popoverWidth: CGFloat = 360
    private let popoverMaxHeight: CGFloat = 480

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let groups = Self.group(tasks: session.tasks)
                ForEach(groups) { group in
                    section(group)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: popoverWidth)
        .frame(maxHeight: popoverMaxHeight)
        .onReceive(timer) { tick in now = tick }
    }

    private func section(_ group: TaskGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(group.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(group.tasks.count)")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 4)
            VStack(spacing: 4) {
                ForEach(group.tasks) { task in
                    BackgroundTaskRow(task: task, now: now) {
                        onSelectTask(task.id)
                    }
                }
            }
        }
    }

    private struct TaskGroup: Identifiable {
        let id: String
        let title: String
        let tasks: [BackgroundTask]
    }

    private static func group(tasks: [BackgroundTask]) -> [TaskGroup] {
        let running = tasks.filter { $0.status == .running }
        let done = tasks.filter { $0.status != .running }
        var out: [TaskGroup] = []
        if !running.isEmpty {
            out.append(
                TaskGroup(
                    id: "running",
                    title: String(localized: "Running"),
                    tasks: running
                )
            )
        }
        if !done.isEmpty {
            // Most-recent completion first reads more like a notification
            // feed than a stale "oldest-first" log. Running tasks already
            // sort by start time (the runtime appends in receive order),
            // so the two sections together read top-to-bottom as
            // newest-relevant → oldest-finished.
            let sorted = done.sorted { lhs, rhs in
                (lhs.endedAt ?? lhs.startedAt) > (rhs.endedAt ?? rhs.startedAt)
            }
            out.append(
                TaskGroup(
                    id: "completed",
                    title: String(localized: "Completed"),
                    tasks: sorted
                )
            )
        }
        return out
    }
}
