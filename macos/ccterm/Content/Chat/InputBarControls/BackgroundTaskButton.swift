import AppKit
import SwiftUI

/// Trigger button rendered in the input-bar chrome row to the right of
/// the permission-mode picker when the session has at least one
/// background bash task in flight or recently completed. Opens a popover
/// listing every task grouped by status.
///
/// Visibility rules — the button stays hidden until the session has
/// produced a task (we don't want a permanent slot on the chrome row
/// for what is currently a per-bash feature). Once the first task
/// appears, the button stays mounted for the rest of the session even
/// after every task terminates — completed entries remain available in
/// the popover so the user can review their output. They cycle out only
/// when `session.tasks` itself empties (currently a CLI-side action via
/// `/tasks clear`; we treat it as an authoritative dismissal signal).
struct BackgroundTaskButton: View {

    let session: Session
    @State private var isPresented = false
    /// Selected task id for the detail sheet. Lives at the button level
    /// (not inside `BackgroundTaskList`) because `.sheet` presents
    /// inside the **enclosing window** — and a popover is its own
    /// window. Hosting the sheet here means it lands centered in the
    /// app window like an Apple Settings sheet, not stacked on top of
    /// the popover bubble.
    @State private var selectedTaskId: String?

    var body: some View {
        let tasks = session.tasks
        if !tasks.isEmpty {
            BarChromeButton(label: {
                HStack(spacing: 6) {
                    runningIndicator(forTasks: tasks)
                    Text(buttonLabel(tasks: tasks))
                        .foregroundStyle(.primary)
                }
            }) {
                isPresented.toggle()
            }
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                BackgroundTaskList(session: session) { taskId in
                    // Tear the popover down before flipping the sheet
                    // on — SwiftUI dismisses popovers when their
                    // anchoring view re-presents in a new way, and a
                    // racing `selectedTaskId = …` would otherwise leave
                    // the popover hanging behind the sheet.
                    isPresented = false
                    selectedTaskId = taskId
                }
            }
            .sheet(item: detailBinding) { task in
                BackgroundTaskDetailSheet(
                    task: task,
                    now: Date(),
                    onStop: stopAction,
                    onDismiss: { selectedTaskId = nil }
                )
            }
            .accessibilityLabel(accessibilityLabel(tasks: tasks))
        }
    }

    /// `.sheet(item:)` re-reads the live `BackgroundTask` off the
    /// session each time it samples — so the sheet observes
    /// status flips that happen while it's open (CLI completing a task
    /// behind the user's back, the stop button updating .status).
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

    private var stopAction: ((String) -> Void)? {
        guard let runtime = session.runtime else { return nil }
        return { taskId in
            runtime.markTaskStoppedLocally(taskId: taskId)
        }
    }

    /// Single 6pt dot, color-coded by whether anything is still running:
    /// green for "live", neutral gray once every task is terminal.
    /// Deliberately not animated — a steady dot reads as a status badge
    /// (cf. Slack's presence dot), whereas a pulse implies urgency we
    /// don't want for a background bash that the user already kicked
    /// off intentionally.
    private func runningIndicator(forTasks tasks: [BackgroundTask]) -> some View {
        let running = tasks.contains { $0.status == .running }
        return Circle()
            .fill(running ? Color.green : Color(nsColor: .tertiaryLabelColor))
            .frame(width: 6, height: 6)
    }

    /// Two states that map directly to the green/gray dot:
    /// - any task running → "%lld running" (count of *running* tasks
    ///   only — the completed ones are visible inside the sheet)
    /// - all terminal → "%lld completed" (count of every task tracked
    ///   on this session)
    /// Singular nouns get their own string so plural rules in zh-Hans
    /// don't need a `%lld 1` rendering.
    private func buttonLabel(tasks: [BackgroundTask]) -> String {
        let running = tasks.filter { $0.status == .running }.count
        if running > 0 {
            return String(localized: "\(running) running")
        }
        return String(localized: "\(tasks.count) completed")
    }

    private func accessibilityLabel(tasks: [BackgroundTask]) -> String {
        let running = tasks.filter { $0.status == .running }.count
        if running > 0 {
            return String(localized: "\(running) running, \(tasks.count) total")
        }
        return String(localized: "\(tasks.count) background tasks")
    }
}
