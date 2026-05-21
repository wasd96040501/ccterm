import Combine
import SwiftUI

/// Popover content for the background-task button. Wider than the
/// other chrome popovers (420pt vs. 240pt) so commands and titles read
/// without wrapping. Height adapts to content with a hard cap and a
/// scroll fallback for long task lists.
///
/// Sections are grouped by status: "Running" first (most likely the
/// user's reason for opening the popover), then "Completed" (which
/// folds in both clean completions and failures so the user sees them
/// in one chronological list — distinguished by the per-card status
/// badge).
struct BackgroundTaskPopover: View {

    let session: Session

    /// Tick on a 1s timer while the popover is open so cards re-render
    /// their elapsed-time counters. The runtime would otherwise only
    /// publish on task state transitions and the counter would freeze.
    @State private var now: Date = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let popoverWidth: CGFloat = 420
    private let popoverMaxHeight: CGFloat = 520

    var body: some View {
        let tasks = session.tasks
        let groups = Self.group(tasks: tasks)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(groups) { group in
                    section(group)
                }
            }
            .padding(12)
        }
        .frame(width: popoverWidth)
        .frame(maxHeight: popoverMaxHeight)
        .onReceive(timer) { tick in now = tick }
    }

    private func section(_ group: TaskGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
            VStack(spacing: 8) {
                ForEach(group.tasks) { task in
                    BackgroundTaskCard(
                        task: task,
                        now: now,
                        onStop: stopAction
                    )
                }
            }
        }
    }

    /// Forwards a card's stop button into the runtime, which flips the
    /// task to `.stopped` immediately so the card reads as terminal
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
