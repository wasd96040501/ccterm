import AppKit
import Charts
import SwiftUI

/// Two stats cards rendered above `NewSessionConfigurator` on the New
/// Session tab. They share the configurator's surface (ultra-thin
/// material + 0.5pt separator stroke + 30pt soft shadow + 16pt corner
/// radius) so the three cards read as one chrome family; the
/// atmospheric accent glow is reserved for the hero (main) card.
///
/// Both cards bind to an *optional* `ClaudeCodeStats.Result`. A `nil`
/// result is a normal first-launch state — every field falls back to
/// `0` and the visual layout is identical to the loaded state (same
/// number of tiles, same heatmap grid, same chart bar count), so the
/// async backfill animates content into a fixed frame instead of
/// growing / shrinking the surrounding chrome. Numeric values use
/// `.contentTransition(.numericText())` for per-digit flips; the
/// caller is expected to wrap the data swap in
/// `withAnimation(.default)`.

// MARK: - Layout

/// Layout constants for the stats-card row. Centralised so the row
/// can be re-arranged or re-sized in one place — every consumer (this
/// file + `TranscriptDetailComposeStack`) references the same numbers.
enum NewSessionStatsCardsLayout {
    /// Both top cards share this height. Picked so the full
    /// three-card stack (top row + spacing + main card) clears the
    /// MacBook Air 13" default-scaled detail-pane height (~740pt
    /// usable after the toolbar overlay and the configurator's
    /// vertical insets) with a few points of buffer.
    static let cardHeight: CGFloat = 180

    /// Wider card (Overview).
    static let overviewWidth: CGFloat = 608

    /// Narrower card (Models). Sums with `overviewWidth + spacing`
    /// to the configurator's `maxWidth` (960) so the three cards
    /// share a left/right edge.
    static let modelsWidth: CGFloat = 336

    /// Horizontal spacing between the two top cards AND vertical
    /// spacing from the top row to the main card. Same value so the
    /// gutter reads uniformly.
    static let spacing: CGFloat = 16
}

// MARK: - Card surface

/// Same material / stroke / shadow / corner as
/// `NewSessionConfigurator`, minus the atmospheric accent glow
/// (which belongs to the hero card only).
private struct StatsCardSurface: ViewModifier {
    static let cornerRadius: CGFloat = InputBarView2.cornerRadius

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 30, x: 0, y: 10)
    }
}

extension View {
    fileprivate func statsCardSurface() -> some View { modifier(StatsCardSurface()) }
}

// MARK: - Overview card

/// Wider top card: 4 compact stat tiles (sessions / messages /
/// tokens / active days) over a 26-week activity heatmap.
struct OverviewStatsCard: View {
    let result: ClaudeCodeStats.Result?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                StatTile(
                    label: String(localized: "Sessions"),
                    value: Double(result?.totalSessions ?? 0),
                    text: Self.compactInt(result?.totalSessions ?? 0))
                StatTile(
                    label: String(localized: "Messages"),
                    value: Double(result?.totalMessages ?? 0),
                    text: Self.compactInt(result?.totalMessages ?? 0))
                StatTile(
                    label: String(localized: "Total tokens"),
                    value: Double(totalTokens),
                    text: Self.compactTokens(totalTokens))
                StatTile(
                    label: String(localized: "Active days"),
                    value: Double(result?.activeDays ?? 0),
                    text: Self.compactInt(result?.activeDays ?? 0))
            }

            ActivityHeatmap(result: result)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(
            width: NewSessionStatsCardsLayout.overviewWidth,
            height: NewSessionStatsCardsLayout.cardHeight
        )
        .statsCardSurface()
    }

    /// Headline "Total tokens" matches Claude desktop: sum of
    /// `input_tokens + output_tokens` across all models. The
    /// `cache_read_input_tokens` and `cache_creation_input_tokens`
    /// fields are *not* included — every turn re-reads the whole
    /// prior context from cache, so adding them inflates the
    /// headline by ~200× and disagrees with the per-model `in · out`
    /// numbers below the chart on the Models card. The aggregator
    /// still stores all four fields separately on
    /// `ClaudeCodeStats.ModelUsage`; the decision to exclude cache
    /// lives at the display boundary so future consumers (e.g. a
    /// detail panel) can still surface cache cost on demand.
    private var totalTokens: Int {
        guard let usage = result?.modelUsage else { return 0 }
        return usage.values.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
    }

    /// Compact integer formatter — short ("1.2k", "168.5k", "12M")
    /// once values cross 10k, raw with thousands separator below.
    static func compactInt(_ n: Int) -> String {
        if n < 10_000 {
            return n.formatted(.number.grouping(.automatic))
        }
        return n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    /// Token-specific compact formatter. Adds "M" / "k" with one
    /// decimal so the headline number doesn't jitter between "999k"
    /// and "1M" on small data deltas.
    static func compactTokens(_ n: Int) -> String {
        if n < 1_000 { return "\(n)" }
        if n < 1_000_000 {
            return String(format: "%.1fk", Double(n) / 1_000)
        }
        if n < 1_000_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        }
        return String(format: "%.1fB", Double(n) / 1_000_000_000)
    }
}

/// One compact value cell. Mirrors the "Sessions: 922" tile from the
/// reference design — eyebrow label on top, big numeric value below.
/// Uses `.contentTransition(.numericText())` so each digit flips
/// individually when the bound value changes inside an animation
/// block.
private struct StatTile: View {
    let label: String
    /// Raw numeric value — feeds `.numericText(value:)` so the
    /// transition knows the direction of the change.
    let value: Double
    /// Pre-formatted display string. Kept separate from `value` so
    /// the formatter can pick `1.2k` style without the transition
    /// having to parse it.
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(text)
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .contentTransition(.numericText(value: value))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

/// GitHub-style activity heatmap. Always renders a 7×N grid where
/// N is computed from the available width — that way the visual
/// frame is stable from the very first frame, even before any data
/// arrives (empty squares). When data lands, the matching cells
/// shift colour inside `.animation(.default)`.
private struct ActivityHeatmap: View {
    let result: ClaudeCodeStats.Result?

    /// Available width is supplied by the parent VStack via
    /// `GeometryReader`. With a fixed 7-row height (`cellHeight`),
    /// we derive cell count to fill the width without leaving a
    /// large right-side gap.
    var body: some View {
        GeometryReader { proxy in
            // Cell sized to fill the row's height; the chosen
            // `cellSize` keeps the heatmap inside the available
            // 90pt slot (7 cells + 6 gaps).
            let cellSize: CGFloat = floor((proxy.size.height - 6 * 2) / 7)
            let gap: CGFloat = 2
            let cols = max(1, Int((proxy.size.width + gap) / (cellSize + gap)))
            // Total days the grid can show; the data range we
            // bucket against is exactly this so the trailing edge
            // is always "today" regardless of card size.
            let totalDays = cols * 7
            let buckets = activityBuckets(days: totalDays)

            HStack(alignment: .top, spacing: gap) {
                ForEach(0..<cols, id: \.self) { col in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { row in
                            let idx = col * 7 + row
                            let v = idx < buckets.count ? buckets[idx] : 0
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(cellColor(value: v))
                                .frame(width: cellSize, height: cellSize)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    /// Returns `days` integers, column-major (column 0 = oldest
    /// week, row 0 = Monday). Each integer is that day's
    /// `messageCount` (or 0 if no activity, or no data at all).
    private func activityBuckets(days: Int) -> [Int] {
        guard days > 0 else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = Calendar(identifier: .gregorian).startOfDay(for: Date())
        // Map of YYYY-MM-DD → message count for fast lookup.
        var byDay: [String: Int] = [:]
        if let result {
            for d in result.dailyActivity {
                byDay[d.date] = d.messageCount
            }
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        var out: [Int] = Array(repeating: 0, count: days)
        for i in 0..<days {
            // Newest day at the trailing edge of the grid; column
            // order is left=oldest → right=newest.
            let offset = days - 1 - i
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                continue
            }
            let key = formatter.string(from: date)
            out[i] = byDay[key] ?? 0
        }
        return out
    }

    /// Map an integer activity count to one of five tints. The base
    /// "no activity" tone is a very faint primary tint so empty grids
    /// still read as a structured surface, not an absent one.
    private func cellColor(value: Int) -> Color {
        switch value {
        case 0: return Color.primary.opacity(0.08)
        case 1..<10: return Color.accentColor.opacity(0.30)
        case 10..<50: return Color.accentColor.opacity(0.50)
        case 50..<150: return Color.accentColor.opacity(0.70)
        default: return Color.accentColor.opacity(0.90)
        }
    }
}

// MARK: - Models card

/// Narrower top card: tiny per-day bar chart of recent token usage
/// on top, top-3 models list with proportion bars below.
struct ModelsStatsCard: View {
    let result: ClaudeCodeStats.Result?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Models"))
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.secondary)

            TokensChart(data: chartData)
                .frame(maxWidth: .infinity)
                .frame(height: 44)

            VStack(spacing: 4) {
                ForEach(topModels, id: \.name) { row in
                    ModelRow(row: row, maxTotal: maxModelTotal)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(
            width: NewSessionStatsCardsLayout.modelsWidth,
            height: NewSessionStatsCardsLayout.cardHeight
        )
        .statsCardSurface()
    }

    /// Last 30 days of total tokens, oldest → newest. Always 30
    /// entries so the chart frame doesn't snap-grow when data lands.
    private var chartData: [TokenDay] {
        let days = 30
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        var totals: [String: Int] = [:]
        if let result {
            for entry in result.dailyModelTokens {
                totals[entry.date] = entry.tokensByModel.values.reduce(0, +)
            }
        }
        var out: [TokenDay] = []
        out.reserveCapacity(days)
        for i in 0..<days {
            let offset = days - 1 - i
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                continue
            }
            let key = formatter.string(from: date)
            out.append(TokenDay(date: date, tokens: totals[key] ?? 0))
        }
        return out
    }

    /// Top 3 models by combined input + output tokens. Stable order
    /// (descending). When `result` is nil, returns 3 placeholder
    /// rows so the layout doesn't collapse from 3 rows to 0 and
    /// jolt the surrounding chrome.
    private var topModels: [ModelRowData] {
        guard let usage = result?.modelUsage else {
            return [
                ModelRowData(name: "—", display: "—", inTokens: 0, outTokens: 0),
                ModelRowData(name: "—", display: "—", inTokens: 0, outTokens: 0),
                ModelRowData(name: "—", display: "—", inTokens: 0, outTokens: 0),
            ]
        }
        let rows: [ModelRowData] = usage.map { (key, value) in
            ModelRowData(
                name: key,
                display: Self.prettyModel(key),
                inTokens: value.inputTokens,
                outTokens: value.outputTokens)
        }
        return Array(rows.sorted { $0.total > $1.total }.prefix(3))
    }

    /// Sum of all token totals — denominator for the per-row
    /// proportion bar so each bar's width reads as "share of all
    /// tokens" not "share of the visible top 3".
    private var maxModelTotal: Int {
        guard let usage = result?.modelUsage else { return 1 }
        let all = usage.values.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
        return max(all, 1)
    }

    /// CLI model names look like
    /// `claude-opus-4-7-20251223` — strip the leading vendor prefix
    /// and trailing date so the row label fits in the narrow card.
    static func prettyModel(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
        // Drop trailing `-YYYYMMDD` if present.
        let comps = s.split(separator: "-")
        if comps.count >= 2, let last = comps.last, last.count == 8, Int(last) != nil {
            s = comps.dropLast().joined(separator: "-")
        }
        // Title-case each segment: `opus-4-7` → `Opus 4.7`. Numbers
        // joined by `-` collapse to `.` for readability.
        let parts = s.split(separator: "-").map { String($0) }
        guard !parts.isEmpty else { return raw }
        var name = parts[0].capitalized
        var nums: [String] = []
        for part in parts.dropFirst() {
            if Int(part) != nil {
                nums.append(part)
            } else {
                if !nums.isEmpty {
                    name += " " + nums.joined(separator: ".")
                    nums.removeAll()
                }
                name += " " + part.capitalized
            }
        }
        if !nums.isEmpty {
            name += " " + nums.joined(separator: ".")
        }
        return name
    }
}

private struct TokenDay: Identifiable {
    let date: Date
    let tokens: Int
    var id: Date { date }
}

private struct ModelRowData {
    let name: String
    let display: String
    let inTokens: Int
    let outTokens: Int
    var total: Int { inTokens + outTokens }
}

private struct TokensChart: View {
    let data: [TokenDay]

    var body: some View {
        Chart(data) { d in
            BarMark(
                x: .value("Date", d.date, unit: .day),
                y: .value("Tokens", d.tokens)
            )
            .foregroundStyle(Color.accentColor.opacity(0.85))
            .cornerRadius(1.5)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { plot in
            plot.background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }
}

private struct ModelRow: View {
    let row: ModelRowData
    let maxTotal: Int

    var body: some View {
        let fraction = Double(row.total) / Double(maxTotal)
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.accentColor.opacity(0.75))
                .frame(width: 6, height: 10)
            Text(row.display)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 78, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: max(0, min(proxy.size.width, proxy.size.width * fraction)))
                }
            }
            .frame(height: 6)
            Text(percentText(fraction))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
                .contentTransition(.numericText(value: fraction))
        }
        .frame(height: 18)
    }

    private func percentText(_ f: Double) -> String {
        if f <= 0 { return "0%" }
        if f < 0.001 { return "<0.1%" }
        if f < 0.1 { return String(format: "%.1f%%", f * 100) }
        return String(format: "%.0f%%", f * 100)
    }
}

// MARK: - Compose stack assembly

/// Stacks the two stat cards on top of the `NewSessionConfigurator`
/// hero card. The whole VStack is centred horizontally and pinned
/// to the configurator's `maxWidth` so all three cards share their
/// left/right edges. Reads the cached `ClaudeCodeStatsService`
/// result from the environment and triggers `refresh()` on first
/// appear (and on every re-mount); the first load on a cold launch
/// renders with zeros and animates the real numbers in.
struct NewSessionComposeStack<InputBar: View>: View {
    @Binding var folderPath: String?
    @Binding var useWorktree: Bool
    @Binding var sourceBranch: String?
    var onResumeSession: ((String) -> Void)? = nil
    @ViewBuilder var inputBar: () -> InputBar

    @Environment(ClaudeCodeStatsService.self) private var stats

    var body: some View {
        VStack(spacing: NewSessionStatsCardsLayout.spacing) {
            HStack(alignment: .top, spacing: NewSessionStatsCardsLayout.spacing) {
                OverviewStatsCard(result: stats.result)
                ModelsStatsCard(result: stats.result)
            }
            // Wrap the data-driven swap in a SwiftUI animation so the
            // numericText transitions on tiles + the BarMark height
            // changes animate together when fresh data lands. The
            // service writes `result` on the main actor; observation
            // fires this re-eval inside the animation block.
            .animation(.default, value: stats.lastUpdated)

            NewSessionConfigurator(
                folderPath: $folderPath,
                useWorktree: $useWorktree,
                sourceBranch: $sourceBranch,
                onResumeSession: onResumeSession,
                inputBar: inputBar
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Re-fire on every mount. The service short-circuits
            // overlapping work (refreshTask cancels its predecessor),
            // so back-to-back New Session opens still result in just
            // one in-flight aggregation.
            stats.refresh()
        }
    }
}

#Preview("Stats cards row") {
    HStack(spacing: NewSessionStatsCardsLayout.spacing) {
        OverviewStatsCard(result: nil)
        ModelsStatsCard(result: nil)
    }
    .padding(40)
    .frame(width: 1040)
    .background(Color(nsColor: .windowBackgroundColor))
}
