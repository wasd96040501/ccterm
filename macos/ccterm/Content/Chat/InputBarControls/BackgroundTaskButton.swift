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
                BackgroundTaskPopover(session: session)
            }
            .accessibilityLabel(accessibilityLabel(tasks: tasks))
        }
    }

    @ViewBuilder
    private func runningIndicator(forTasks tasks: [BackgroundTask]) -> some View {
        let running = tasks.contains { $0.status == .running }
        if running {
            PulsingDot()
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func buttonLabel(tasks: [BackgroundTask]) -> String {
        if tasks.count == 1 {
            return String(localized: "1 task")
        }
        return String(localized: "\(tasks.count) tasks")
    }

    private func accessibilityLabel(tasks: [BackgroundTask]) -> String {
        let running = tasks.filter { $0.status == .running }.count
        if running > 0 {
            return String(localized: "\(running) running, \(tasks.count) total")
        }
        return String(localized: "\(tasks.count) background tasks")
    }
}

/// 6pt accent-tinted dot that pulses 1.0 ↔ 0.4 every 1.4 seconds. Drives
/// the "task running" affordance on the chrome button. Repeated work
/// fields in Apple's design language: progress chips in Mail's
/// network-status header, the live recording indicator in QuickTime.
struct PulsingDot: View {
    @State private var pulse: Bool = false

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
            .opacity(pulse ? 1.0 : 0.4)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}
