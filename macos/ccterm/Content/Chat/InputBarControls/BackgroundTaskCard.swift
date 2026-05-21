import AppKit
import SwiftUI

/// One row in the background-task popover. Header is always visible:
/// status icon · title · elapsed time · disclosure chevron. Tapping the
/// header expands the card and reveals the captured command + a tailing
/// view of the spool file's output.
///
/// Output streaming is opt-in: the `BackgroundTaskOutputStream` allocates
/// its file descriptor on first expansion and tears it down on collapse,
/// so a popover containing 30 cards doesn't open 30 fds at once.
struct BackgroundTaskCard: View {

    let task: BackgroundTask
    /// Forwarded from the parent so the card can update the wall-clock
    /// counter on a 1-second cadence without owning its own timer. nil
    /// when the popover hasn't ticked yet.
    let now: Date
    /// Invoked when the user clicks the trailing "Stop" affordance on a
    /// running card. nil disables the stop button (rendered for terminal
    /// cards, for tests, or any caller that wants to forbid local
    /// stops).
    var onStop: ((String) -> Void)? = nil

    @State private var isExpanded: Bool = false
    @State private var stream: BackgroundTaskOutputStream?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .contentShape(Rectangle())
                .onTapGesture { toggle() }
            if isExpanded {
                Divider()
                    .padding(.horizontal, 12)
                expandedBody
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .animation(.easeOut(duration: 0.18), value: isExpanded)
        .onChange(of: task.outputFile) { _, newPath in
            // CLI's output path can land a moment after task_started.
            // Re-bind the stream when the path materialises while the
            // card is expanded.
            if isExpanded, let newPath, stream?.path != newPath {
                stream = BackgroundTaskOutputStream(path: newPath)
                stream?.start()
            }
        }
        .onDisappear { stream?.stop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            statusBadge
            VStack(alignment: .leading, spacing: 2) {
                Text(titleLine)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitleLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            if task.status == .running, let onStop {
                Button {
                    onStop(task.id)
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(
                            Circle().fill(Color.primary.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .help(String(localized: "Stop task"))
            }
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var statusBadge: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.16))
                .frame(width: 22, height: 22)
            Image(systemName: statusIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(statusColor)
        }
    }

    private var statusIcon: String {
        switch task.status {
        case .running: return "circle.dotted"
        case .completed: return "checkmark"
        case .failed: return "exclamationmark"
        case .stopped: return "stop.fill"
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .running: return .accentColor
        case .completed: return .green
        case .failed: return .red
        case .stopped: return Color(nsColor: .systemGray)
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
        let kind = displayKind
        let timing = elapsedDescription
        if !kind.isEmpty {
            return "\(kind) · \(timing)"
        }
        return timing
    }

    private var displayKind: String {
        switch task.taskType?.lowercased() {
        case "local_bash"?: return String(localized: "bash")
        case nil: return ""
        case let other?: return other.replacingOccurrences(of: "_", with: " ")
        }
    }

    private var elapsedDescription: String {
        let endpoint = task.endedAt ?? now
        let interval = max(0, endpoint.timeIntervalSince(task.startedAt))
        let timing = Self.formatElapsed(interval)
        switch task.status {
        case .running: return String(localized: "running · \(timing)")
        case .completed: return String(localized: "completed · \(timing)")
        case .failed: return String(localized: "failed · \(timing)")
        case .stopped: return String(localized: "stopped · \(timing)")
        }
    }

    // MARK: - Expanded body

    @ViewBuilder
    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let command = task.command, !command.isEmpty {
                Text(command)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                    )
            }
            outputSection
            if let summary = task.summary, task.isTerminal {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var outputSection: some View {
        Group {
            if let stream {
                BackgroundTaskOutputView(stream: stream)
            } else if task.outputFile == nil {
                outputPlaceholder(text: String(localized: "Waiting for output…"))
            } else {
                outputPlaceholder(text: String(localized: "Loading output…"))
            }
        }
    }

    private func outputPlaceholder(text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
            )
    }

    // MARK: - Behaviour

    private func toggle() {
        isExpanded.toggle()
        if isExpanded, let path = task.outputFile {
            if stream?.path != path {
                stream = BackgroundTaskOutputStream(path: path)
            }
            stream?.start()
        } else {
            stream?.stop()
            stream = nil
        }
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

/// Scrollable monospaced view over the tailing stream. Kept separate so
/// the card can swap streams (after `outputFile` resolves) without
/// rebuilding the scroll view's geometry.
private struct BackgroundTaskOutputView: View {
    @Bindable var stream: BackgroundTaskOutputStream

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(displayed)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .id("tail")
            }
            .frame(maxHeight: 220)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
            )
            .onChange(of: stream.text) { _, _ in
                // Auto-scroll to the tail every time the buffer grows.
                // No animation — output streaming should feel like a
                // terminal scrollback, not a bouncing animation.
                proxy.scrollTo("tail", anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo("tail", anchor: .bottom)
            }
        }
    }

    private var displayed: String {
        if !stream.text.isEmpty { return stream.text }
        if stream.fileMissing {
            return String(localized: "Waiting for output…")
        }
        if stream.isStarting {
            return String(localized: "Loading…")
        }
        return String(localized: "(no output yet)")
    }
}
