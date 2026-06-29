import AgentSDK
import Foundation

/// Formatting helpers for background-task rows / detail — the status label, the
/// status-plus-timing subtitle, and the compact elapsed-duration string.
/// SwiftUI-free (`String(localized:)` + the `BackgroundTask` model only), so the
/// AppKit `BackgroundTaskPickerController` + `BackgroundTaskDetailPresenter` read
/// them directly.
///
/// Lifted verbatim out of the deleted SwiftUI `BackgroundTaskRow.swift` during
/// the D8 dead-SwiftUI sweep — `BackgroundTaskFormat` is on the migration-plan
/// §4.2 reused-verbatim list.
enum BackgroundTaskFormat {

    /// Localized status label keyed off the BackgroundTask.Status enum.
    static func statusLabel(_ status: BackgroundTask.Status) -> String {
        switch status {
        case .running: return String(localized: "Running")
        case .completed: return String(localized: "Completed")
        case .failed: return String(localized: "Failed")
        case .stopped: return String(localized: "Stopped")
        }
    }

    /// "Running · 2m 15s" / "Completed · 4s" — used in the row subtitle.
    static func statusedSubtitle(task: BackgroundTask, timing: String) -> String {
        let label = statusLabel(task.status)
        return "\(label) · \(timing)"
    }

    /// Compact human duration: <1s, Ns, Nm Ns, Nh Nm.
    static func elapsedDescription(task: BackgroundTask, now: Date) -> String {
        let endpoint = task.endedAt ?? now
        let interval = max(0, endpoint.timeIntervalSince(task.startedAt))
        return formatElapsed(interval)
    }

    static func formatElapsed(_ interval: TimeInterval) -> String {
        if interval < 1 {
            return String(localized: "<1s")
        }
        let totalSeconds = Int(interval)
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes < 60 {
            return "\(minutes)m \(seconds)s"
        }
        let hours = minutes / 60
        let mins = minutes % 60
        return "\(hours)h \(mins)m"
    }
}
