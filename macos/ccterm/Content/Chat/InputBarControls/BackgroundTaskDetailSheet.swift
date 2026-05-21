import AppKit
import SwiftUI

/// Modal sheet presenting one background task's full state. Opened
/// from `BackgroundTaskRow` in the popover. Larger than the
/// popover (640pt wide) and re-uses the host window's sheet chrome —
/// Esc / close button dismisses.
///
/// Layout hierarchy (top-to-bottom):
///
/// ```
/// ┌──────────────────────────────────────────────────┐
/// │ Title bar                                  [×]   │
/// │   Description (semibold 17pt)                    │
/// │   Status pill · Type · Elapsed                   │
/// ├──────────────────────────────────────────────────┤
/// │ COMMAND                                          │
/// │   ┌──────────────────────────────────────────┐   │
/// │   │ shell-styled monospaced block            │   │
/// │   └──────────────────────────────────────────┘   │
/// │ OUTPUT                                           │
/// │   ┌──────────────────────────────────────────┐   │
/// │   │ tail-style monospaced stream             │   │
/// │   │ (scroll, max-height bound by sheet body) │   │
/// │   └──────────────────────────────────────────┘   │
/// ├──────────────────────────────────────────────────┤
/// │ Started 2:34 PM · Ended 2:36 PM        [ Stop ]  │
/// └──────────────────────────────────────────────────┘
/// ```
///
/// Apple style notes:
/// - Section headers use small-caps secondary text (mirrors Mac
///   Settings panes — "GENERAL" / "ADVANCED").
/// - Content cards have a single corner radius (8pt), no shadow, with a
///   subtle hairline border tinted by `separatorColor`.
/// - Status pill is the only saturated color on the page; everything
///   else stays in label / secondary / tertiary tones so the eye lands
///   on the status first.
struct BackgroundTaskDetailSheet: View {

    let task: BackgroundTask
    let now: Date
    var onStop: ((String) -> Void)? = nil
    let onDismiss: () -> Void

    @State private var stream: BackgroundTaskOutputStream?

    private let sheetWidth: CGFloat = 640
    private let sheetIdealHeight: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    commandSection
                    outputSection
                    if let summary = task.summary, task.isTerminal {
                        summarySection(text: summary)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: sheetWidth)
        .frame(minHeight: 360, idealHeight: sheetIdealHeight, maxHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: task.outputFile) { rebindStream() }
        .onDisappear { stream?.stop() }
    }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(titleLine)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                metaRow
            }
            Spacer(minLength: 16)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle().fill(Color.primary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(String(localized: "Close"))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var metaRow: some View {
        HStack(spacing: 10) {
            statusPill
            if let kind = displayKind, !kind.isEmpty {
                metaDot()
                Text(kind)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            metaDot()
            Text(elapsedLine)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(BackgroundTaskFormat.statusLabel(task.status))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(statusColor.opacity(0.14))
        )
    }

    /// 3pt circular separator between metadata fields. Reads more
    /// quietly than a middle-dot character — the dot character has
    /// font-dependent baseline drift, the geometry stays put.
    private func metaDot() -> some View {
        Circle()
            .fill(Color(nsColor: .quaternaryLabelColor))
            .frame(width: 3, height: 3)
    }

    // MARK: - Sections

    private var commandSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(String(localized: "Command"))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(task.command ?? "—")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .overlay(cardBorder)
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionHeader(String(localized: "Output"))
                if task.status == .running, stream != nil {
                    Text(String(localized: "Live"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.14)))
                }
                Spacer(minLength: 0)
                if let path = task.outputFile {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                }
            }
            outputBody
        }
    }

    @ViewBuilder
    private var outputBody: some View {
        if let stream {
            BackgroundTaskOutputView(stream: stream)
                .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 280)
                .background(cardBackground)
                .overlay(cardBorder)
        } else if task.outputFile == nil {
            outputPlaceholder(String(localized: "No output file available"))
        } else {
            outputPlaceholder(String(localized: "Loading output…"))
        }
    }

    private func outputPlaceholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            .padding(12)
            .background(cardBackground)
            .overlay(cardBorder)
    }

    private func summarySection(text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(String(localized: "Result"))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(cardBackground)
                .overlay(cardBorder)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                timestampLine(label: String(localized: "Started"), date: task.startedAt)
                if let ended = task.endedAt {
                    timestampLine(label: String(localized: "Ended"), date: ended)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            Spacer(minLength: 0)
            if task.status == .running, let onStop {
                Button {
                    onStop(task.id)
                } label: {
                    Label(String(localized: "Stop"), systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func timestampLine(label: String, date: Date) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.tertiary)
            Text(date, format: .dateTime.hour().minute().second())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Style helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.6)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
    }

    // MARK: - Derived values

    private var titleLine: String {
        if let desc = task.description, !desc.isEmpty { return desc }
        if let cmd = task.command, !cmd.isEmpty {
            return cmd.split(separator: "\n").first.map(String.init) ?? cmd
        }
        return String(localized: "Background task")
    }

    private var displayKind: String? {
        switch task.taskType?.lowercased() {
        case "local_bash"?: return String(localized: "bash")
        case nil: return nil
        case let other?: return other.replacingOccurrences(of: "_", with: " ")
        }
    }

    private var elapsedLine: String {
        let timing = BackgroundTaskFormat.elapsedDescription(task: task, now: now)
        return timing
    }

    private var statusColor: Color {
        switch task.status {
        case .running: return .green
        case .completed: return Color(nsColor: .secondaryLabelColor)
        case .failed: return .red
        case .stopped: return .orange
        }
    }

    private func rebindStream() {
        guard let path = task.outputFile else {
            stream?.stop()
            stream = nil
            return
        }
        if stream?.path != path {
            stream?.stop()
            let next = BackgroundTaskOutputStream(path: path)
            stream = next
            next.start()
        } else {
            stream?.start()
        }
    }
}

// MARK: - Output view

/// Scrollable monospaced view over the tailing stream. Kept separate so
/// the sheet can swap streams (after `outputFile` resolves) without
/// rebuilding the scroll view's geometry.
struct BackgroundTaskOutputView: View {
    @Bindable var stream: BackgroundTaskOutputStream

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(displayed)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .id("tail")
            }
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
