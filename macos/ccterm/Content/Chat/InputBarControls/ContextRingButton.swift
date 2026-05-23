import AgentSDK
import SwiftUI

/// Footer-row indicator: how much of the model's context window the
/// running session has used. The ring is a clickable button — tapping
/// it opens a popover with the absolute numbers and percentage.
///
/// Always renders, including when `contextWindowTokens` is still zero
/// (CLI hasn't reported a window yet, or the session has just started).
/// The empty-state ring shows a 0% track; the user expects the chrome
/// row to keep its shape between sessions rather than have a slot
/// appear and disappear under it.
struct ContextRingButton: View {
    let session: Session
    @State private var isPresented = false

    var body: some View {
        Button(action: { isPresented.toggle() }) {
            ProgressRingView(percent: percent)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            ContextPopoverContent(session: session, isPresented: $isPresented)
        }
        .accessibilityLabel(String(localized: "Context usage"))
        .accessibilityValue("\(Int(percent.rounded()))%")
    }

    /// Raw 0..100 value used by the ring fill animation. We keep the
    /// fractional precision here so the stroke arc moves smoothly
    /// between integer ticks; the popover and accessibility label
    /// rounds it before display (matches the JS reference's
    /// `Math.round(used / total * 100)`).
    private var percent: Double {
        let total = Double(session.contextWindowTokens)
        guard total > 0 else { return 0 }
        let used = Double(session.contextUsedTokens)
        return min(max(used / total * 100, 0), 100)
    }
}

// MARK: - Popover content

/// Two-section popover:
/// 1. Detailed breakdown from the CLI's `get_context_usage` RPC (bar +
///    per-category rows + expandable Memory files / MCP tools). Only
///    rendered once the typed `ContextUsage` lands; absent on old CLIs
///    that never respond, or on `.draft` sessions with no live RPC.
/// 2. The compact "used / total (n%)" summary below a divider. Always
///    visible so the popover still serves the no-CLI case.
private struct ContextPopoverContent: View {
    let session: Session
    @Binding var isPresented: Bool

    /// Last time we triggered a refresh for *this* popover open. Used to
    /// avoid hammering the CLI when SwiftUI re-renders the popover body
    /// (e.g. when `contextUsage` lands and the view re-evaluates).
    @State private var didRequest = false

    private static let popoverWidth: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let usage = session.contextUsage {
                ContextBreakdownView(usage: usage)
                Divider().padding(.horizontal, 12).padding(.vertical, 8)
            } else if session.isFetchingContextUsage {
                fetchingPlaceholder
                Divider().padding(.horizontal, 12).padding(.vertical, 8)
            }
            summarySection
        }
        .padding(PopoverList.outerPadding)
        .frame(width: Self.popoverWidth)
        .onAppear { requestIfNeeded() }
    }

    private func requestIfNeeded() {
        guard !didRequest else { return }
        didRequest = true
        session.requestContextUsage()
    }

    private var fetchingPlaceholder: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(String(localized: "Loading context breakdown…"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var summarySection: some View {
        HStack(alignment: .center, spacing: 10) {
            ProgressRingView(percent: percent, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(usageLine)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                Text(percentLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PopoverList.horizontalInset + 2)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private var used: Int { session.contextUsedTokens }
    private var total: Int { session.contextWindowTokens }
    private var percent: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(used) / Double(total) * 100, 0), 100)
    }
    private var usageLine: String {
        "\(formatTokens(used)) / \(formatTokens(total))"
    }
    private var percentLine: String {
        String(format: String(localized: "%lld%% used"), Int(percent.rounded()))
    }
}

// MARK: - Breakdown (header + bar + rows + expandable details)

private struct ContextBreakdownView: View {
    let usage: ContextUsage

    /// Pre-sorted category list mirroring the JS reference's display
    /// order: active rows by tokens desc, then deferred rows by tokens
    /// desc, then the buffer row, then Free space.
    private var ordered: [ContextUsage.Category] {
        let buffer = usage.categories.first { isBufferName($0.name) }
        let free = usage.categories.first { $0.name == "Free space" }
        let active = usage.categories
            .filter { !$0.isDeferred && $0.name != "Free space" && !isBufferName($0.name) }
            .sorted { $0.tokens > $1.tokens }
        let deferred = usage.categories
            .filter { $0.isDeferred }
            .sorted { $0.tokens > $1.tokens }
        return active + deferred + (buffer.map { [$0] } ?? []) + (free.map { [$0] } ?? [])
    }

    /// Sum used for bar segment widths. Includes every visible category
    /// (active + deferred + buffer + free) so the bar always fills the
    /// full width.
    private var displaySum: Int {
        max(1, ordered.reduce(0) { $0 + $1.tokens })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            barTrack
            VStack(spacing: 2) { ForEach(Array(ordered.enumerated()), id: \.element.name) { idx, cat in
                CategoryRow(category: cat, rankInActive: rankInActive(at: idx), rawMaxTokens: usage.rawMaxTokens)
            } }
            if !usage.memoryFiles.isEmpty {
                ExpandableGroup(
                    label: String(localized: "Memory files"),
                    totalTokens: usage.memoryFiles.reduce(0) { $0 + $1.tokens },
                    count: usage.memoryFiles.count,
                    rows: usage.memoryFiles.map { ($0.path, $0.tokens) }
                )
            }
            if !usage.mcpTools.isEmpty {
                ExpandableGroup(
                    label: String(localized: "MCP tools"),
                    totalTokens: usage.mcpTools.reduce(0) { $0 + $1.tokens },
                    count: usage.mcpTools.count,
                    rows: usage.mcpTools.map { ("\($0.serverName) · \($0.name)", $0.tokens) }
                )
            }
            if !usage.agents.isEmpty {
                ExpandableGroup(
                    label: String(localized: "Custom agents"),
                    totalTokens: usage.agents.reduce(0) { $0 + $1.tokens },
                    count: usage.agents.count,
                    rows: usage.agents.map { ($0.agentType, $0.tokens) }
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(String(localized: "Context window"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Text(headerSummary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var headerSummary: String {
        let used = formatTokens(usage.totalTokens)
        let max = formatTokens(usage.rawMaxTokens)
        return "\(used) / \(max) (\(usage.percentage)%)"
    }

    private var barTrack: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(ordered.enumerated()), id: \.element.name) { idx, cat in
                    let proportion = Double(cat.tokens) / Double(displaySum)
                    if proportion >= 0.005 {  // skip slivers < 0.5%
                        Rectangle()
                            .fill(barColor(for: cat, rankInActive: rankInActive(at: idx)))
                            .frame(width: geo.size.width * CGFloat(proportion))
                    }
                }
            }
        }
        .frame(height: 6)
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.6))
        }
    }

    /// How many active (non-deferred / non-buffer / non-free) entries
    /// come at or before this index. Used to colour-step the active
    /// segments while keeping deferred + buffer + free uniformly gray.
    private func rankInActive(at index: Int) -> Int {
        var rank = 0
        for i in 0...index {
            let cat = ordered[i]
            if !cat.isDeferred && cat.name != "Free space" && !isBufferName(cat.name) {
                if i == index { return rank }
                rank += 1
            }
        }
        return rank
    }

    private func barColor(for cat: ContextUsage.Category, rankInActive: Int) -> Color {
        Self.color(for: cat, rankInActive: rankInActive)
    }

    static func color(for cat: ContextUsage.Category, rankInActive: Int) -> Color {
        if cat.name == "Free space" {
            return Color(nsColor: .quaternaryLabelColor).opacity(0.4)
        }
        if cat.isDeferred || isBufferName(cat.name) {
            return Color(nsColor: .quaternaryLabelColor)
        }
        // Active rows: step from full accent down toward a pale tint as
        // rank grows. Cap at 6 steps so very long lists still differ.
        let step = min(rankInActive, 6)
        let opacity = 1.0 - Double(step) * 0.12
        return Color.accentColor.opacity(max(0.35, opacity))
    }
}

private func isBufferName(_ name: String) -> Bool {
    name == "Autocompact buffer" || name == "Compact buffer"
}

// MARK: - Single category row

private struct CategoryRow: View {
    let category: ContextUsage.Category
    let rankInActive: Int
    let rawMaxTokens: Int

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(ContextBreakdownView.color(for: category, rankInActive: rankInActive))
                .frame(width: 8, height: 8)
            Text(category.name)
                .font(.system(size: 12))
                .foregroundStyle(category.isDeferred ? .secondary : .primary)
            Spacer(minLength: 6)
            Text(formatTokens(category.tokens))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(percentString)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var percentString: String {
        guard rawMaxTokens > 0 else { return "0%" }
        let pct = Double(category.tokens) / Double(rawMaxTokens) * 100
        // One decimal place to match the screenshot ("1.1%", "0.3%").
        return String(format: "%.1f%%", pct)
    }
}

// MARK: - Expandable detail group (Memory files / MCP tools / Custom agents)

private struct ExpandableGroup: View {
    let label: String
    let totalTokens: Int
    let count: Int
    /// (display name, tokens) pairs in the order to render.
    let rows: [(String, Int)]

    @State private var isOpen = false

    var body: some View {
        VStack(spacing: 2) {
            Button(action: { isOpen.toggle() }) {
                HStack(spacing: 6) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text(label)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 6)
                    Text(formatTokens(totalTokens))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text("\(count)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 8) {
                            Color.clear.frame(width: 10, height: 8)
                            Text(row.0)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 6)
                            Text(formatTokens(row.1))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Color.clear.frame(width: 44, height: 8)
                        }
                    }
                }
                .frame(maxHeight: rows.count > 8 ? 160 : .infinity)
                .clipped()
            }
        }
    }
}

// MARK: - Formatting

private func formatTokens(_ count: Int) -> String {
    if count >= 1_000_000_000 {
        return String(format: "%.1fB", Double(count) / 1_000_000_000)
    }
    if count >= 1_000_000 {
        return String(format: "%.1fM", Double(count) / 1_000_000)
    }
    if count >= 1000 {
        return String(format: "%.1fk", Double(count) / 1000)
    }
    return String(count)
}
