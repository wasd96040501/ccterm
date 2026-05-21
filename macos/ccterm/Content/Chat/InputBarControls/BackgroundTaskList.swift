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

    /// Tick on a 1s timer while the popover is open so rows re-render
    /// their elapsed-time counters. The runtime would otherwise only
    /// publish on task state transitions and the counter would freeze.
    @State private var now: Date = Date()
    @State private var selectedTaskId: String?
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
        .sheet(item: detailBinding) { task in
            BackgroundTaskDetailSheet(
                task: task,
                now: now,
                onStop: stopAction,
                onDismiss: { selectedTaskId = nil }
            )
        }
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
                        selectedTaskId = task.id
                    }
                }
            }
        }
    }

    /// `.sheet(item:)` needs a `Binding<BackgroundTask?>`. We don't
    /// store the task itself — only its id — so the binding looks
    /// up the live record off the session each time it's read. That
    /// way mid-sheet status flips (CLI completes the task while the
    /// sheet is open) propagate without rebuilding the binding.
    private var detailBinding: Binding<BackgroundTask?> {
        Binding(
            get: {
                guard let id = selectedTaskId else { return nil }
                return session.tasks.first(where: { $0.id == id })
            },
            set: { newValue in
                selectedTaskId = newValue?.id
            }
        )
    }

    /// Forwards a row's stop affordance into the runtime, which flips the
    /// task to `.stopped` immediately so the sheet reads as terminal
    /// without waiting for the CLI's task_notification round-trip. The
    /// CLI's notification eventually arrives and re-confirms the
    /// terminal state (idempotent — markTaskStoppedLocally is a no-op
    /// for non-running tasks).
    private var stopAction: ((String) -> Void)? {
        guard let runtime = session.runtime else { return nil }
        return { taskId in
            runtime.markTaskStoppedLocally(taskId: taskId)
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
