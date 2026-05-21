import SwiftUI

/// One row inside the background-task popover. Single tap opens the
/// detail sheet. Compact by design — only a small status dot, a
/// one-line title, a one-line subtitle (elapsed time + status), and a
/// trailing disclosure chevron. The popover stays narrow (360pt) so
/// the row's hierarchy reads in a single glance; everything else
/// (command, output, summary) lives in the sheet.
struct BackgroundTaskRow: View {

    let task: BackgroundTask
    let now: Date
    let onSelect: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 10) {
                statusDot
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleLine)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subtitleLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.linear(duration: 0.08), value: isHovering)
    }

    /// 8pt color-coded dot. No background ring, no symbol inside — the
    /// row hierarchy puts the title in the primary slot, so the status
    /// is supporting information.
    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch task.status {
        case .running: return .green
        case .completed: return Color(nsColor: .tertiaryLabelColor)
        case .failed: return .red
        case .stopped: return .orange
        }
    }

    private var titleLine: String {
        if let desc = task.description, !desc.isEmpty { return desc }
        if let cmd = task.command, !cmd.isEmpty {
            return cmd.split(separator: "\n").first.map(String.init) ?? cmd
        }
        return String(localized: "Background task")
    }

    private var subtitleLine: String {
        let timing = BackgroundTaskFormat.elapsedDescription(
            task: task, now: now)
        return BackgroundTaskFormat.statusedSubtitle(
            task: task, timing: timing)
    }
}

/// Shared formatting for the row + the detail sheet so the wording
/// matches between the two surfaces.
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
