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

/// Weekly activity heatmap — 26 columns (≈ half a year) × 7 rows
/// (Monday row 0 → Sunday row 6). The rightmost column is the
/// current week and only paints cells for days that have already
/// happened; future days in that week render as transparent space
/// instead of a "no activity" tile, so the leading edge reads as
/// "the week is still in progress".
///
/// Cell intensity buckets daily tokens (sum of `tokensByModel`,
/// already `input + output` only — no cache) into 4 tones: a
/// neutral empty colour and three distinct blue tiers whose
/// thresholds are the 33rd / 66th percentile of non-zero days in
/// the visible window (adaptive: a light user and a heavy user
/// each get the full tier range, instead of everything saturating
/// at the top tier for the heavy user).
///
/// Hover is zero-delay: a single `.onContinuousHover` on the grid
/// computes which cell is under the cursor from the hover location
/// (cellSize + gap), and an overlay bubble shows `date · tokens`
/// next to the cell. `.help(...)` is intentionally not used — it
/// goes through `NSToolTip` and inherits the ~1.5s system delay.
private struct ActivityHeatmap: View {
    let result: ClaudeCodeStats.Result?

    @State private var hovered: HoveredHeatmapCell?

    /// 26 columns × 7 rows. Tied to the "half year" spec — bumping
    /// either dimension would require resizing the card.
    private static let columns = 26
    private static let rows = 7
    /// Fixed cell + gap so the grid's natural width is stable
    /// regardless of the parent's available width. The grid is
    /// left-aligned in the card; the right-hand whitespace is
    /// reserved deliberately and could host a legend later.
    /// `12 × 26 + 2 × 25 = 362` wide; `12 × 7 + 2 × 6 = 96` tall —
    /// fits the ~96pt slot below the stat-tile row in a 180pt card.
    private static let cellSize: CGFloat = 12
    private static let gap: CGFloat = 2

    private static var gridWidth: CGFloat {
        CGFloat(columns) * cellSize + CGFloat(columns - 1) * gap
    }
    private static var gridHeight: CGFloat {
        CGFloat(rows) * cellSize + CGFloat(rows - 1) * gap
    }

    var body: some View {
        let grid = buildGrid()
        let thresholds = computeThresholds(grid: grid)

        ZStack(alignment: .topLeading) {
            heatmapGrid(grid: grid, thresholds: thresholds)
                .frame(width: Self.gridWidth, height: Self.gridHeight)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        updateHovered(at: location, grid: grid)
                    case .ended:
                        hovered = nil
                    }
                }
            if let info = hovered {
                tooltipBubble(for: info)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func heatmapGrid(grid: [[HeatmapCell?]], thresholds: (Int, Int)?) -> some View {
        HStack(alignment: .top, spacing: Self.gap) {
            ForEach(0..<Self.columns, id: \.self) { col in
                VStack(spacing: Self.gap) {
                    ForEach(0..<Self.rows, id: \.self) { row in
                        if let cell = grid[col][row] {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(color(for: cell.tokens, thresholds: thresholds))
                                .frame(width: Self.cellSize, height: Self.cellSize)
                        } else {
                            // Future day in the current week — no
                            // tile, just transparent space so the
                            // column's height stays consistent with
                            // the other columns.
                            Color.clear
                                .frame(width: Self.cellSize, height: Self.cellSize)
                        }
                    }
                }
            }
        }
    }

    private func updateHovered(at location: CGPoint, grid: [[HeatmapCell?]]) {
        let step = Self.cellSize + Self.gap
        let col = Int(location.x / step)
        let row = Int(location.y / step)
        guard col >= 0, col < Self.columns, row >= 0, row < Self.rows,
            let cell = grid[col][row]
        else {
            hovered = nil
            return
        }
        hovered = HoveredHeatmapCell(col: col, row: row, cell: cell)
    }

    /// Tooltip placed *near* the cell (above for bottom-half rows,
    /// below for top-half rows so the bubble stays inside the
    /// heatmap's vertical band). Horizontal centre clamps to the
    /// grid's bounds so edge cells don't render the bubble half-
    /// outside the card; the bubble width is approximated, exact
    /// width measurement isn't worth a `GeometryReader` round-trip.
    @ViewBuilder
    private func tooltipBubble(for info: HoveredHeatmapCell) -> some View {
        let step = Self.cellSize + Self.gap
        let cellCenterX = CGFloat(info.col) * step + Self.cellSize / 2
        let cellCenterY = CGFloat(info.row) * step + Self.cellSize / 2
        let placeBelow = info.row < 4
        let halfCell = Self.cellSize / 2
        // Bubble half-height (~16pt for the two-line layout) plus
        // a small visual gap to the cell.
        let yOffset: CGFloat = placeBelow ? halfCell + 18 : -halfCell - 18
        let estimatedHalfWidth: CGFloat = 56
        let clampedX = min(
            max(cellCenterX, estimatedHalfWidth),
            Self.gridWidth - estimatedHalfWidth)

        VStack(alignment: .leading, spacing: 1) {
            Text(Self.dateLabel(for: info.cell.date))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Text(Self.tokensLabel(for: info.cell.tokens))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.black.opacity(0.85))
        )
        .fixedSize()
        .position(x: clampedX, y: cellCenterY + yOffset)
        .allowsHitTesting(false)
    }

    // MARK: - Grid construction

    /// Builds the 26 × 7 grid. Column 0 = the Monday 25 weeks back,
    /// column 25 = this week's Monday. Within a column, row 0 = the
    /// week's Monday, row 6 = Sunday. Days past `today` render as
    /// `nil` so the current-week column trails off.
    private func buildGrid() -> [[HeatmapCell?]] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        cal.firstWeekday = 2  // Monday
        let today = cal.startOfDay(for: Date())
        // Calendar's `weekday` is 1 (Sunday) … 7 (Saturday). For a
        // Monday-first week, the offset back to Monday is
        // (weekday + 5) % 7 — Mon→0, Tue→1, …, Sun→6.
        let weekday = cal.component(.weekday, from: today)
        let mondayOffset = (weekday + 5) % 7
        guard
            let thisMonday = cal.date(byAdding: .day, value: -mondayOffset, to: today),
            let firstMonday = cal.date(
                byAdding: .weekOfYear, value: -(Self.columns - 1), to: thisMonday)
        else {
            return Array(
                repeating: Array(repeating: nil, count: Self.rows), count: Self.columns)
        }

        var tokensByDay: [String: Int] = [:]
        if let result {
            for entry in result.dailyModelTokens {
                tokensByDay[entry.date] = entry.tokensByModel.values.reduce(0, +)
            }
        }
        let dayFmt = DateFormatter()
        dayFmt.calendar = cal
        dayFmt.timeZone = cal.timeZone
        dayFmt.dateFormat = "yyyy-MM-dd"

        var grid: [[HeatmapCell?]] = Array(
            repeating: Array(repeating: nil, count: Self.rows), count: Self.columns)
        for col in 0..<Self.columns {
            guard let weekStart = cal.date(byAdding: .day, value: col * 7, to: firstMonday)
            else { continue }
            for row in 0..<Self.rows {
                guard let cellDate = cal.date(byAdding: .day, value: row, to: weekStart)
                else { continue }
                if cellDate > today { continue }  // future → leave nil
                let key = dayFmt.string(from: cellDate)
                grid[col][row] = HeatmapCell(date: cellDate, tokens: tokensByDay[key] ?? 0)
            }
        }
        return grid
    }

    /// Returns (p33, p66) of non-zero daily token counts in the
    /// visible grid; `nil` when fewer than three non-zero days
    /// exist (in which case any non-zero day reads as the top tier
    /// — no useful split is possible).
    private func computeThresholds(grid: [[HeatmapCell?]]) -> (Int, Int)? {
        let values = grid.flatMap { $0 }
            .compactMap { $0?.tokens }
            .filter { $0 > 0 }
            .sorted()
        guard values.count >= 3 else { return nil }
        return (values[values.count / 3], values[(values.count * 2) / 3])
    }

    private func color(for tokens: Int, thresholds: (Int, Int)?) -> Color {
        if tokens == 0 { return Self.emptyColor }
        guard let thresholds else { return Self.tierColors[2] }
        if tokens < thresholds.0 { return Self.tierColors[0] }
        if tokens < thresholds.1 { return Self.tierColors[1] }
        return Self.tierColors[2]
    }

    /// Neutral mid-gray. Picked so empty cells read as "no activity"
    /// without competing with the blue tier colours on the same
    /// ultra-thin material.
    private static let emptyColor = Color(white: 0.32).opacity(0.45)
    /// Three explicit blues with increasing chroma — opacity-only
    /// shading on the ultra-thin material doesn't separate the
    /// tiers cleanly enough (the material's translucency washes
    /// out low-opacity blues), so each tier gets its own RGB triple.
    private static let tierColors: [Color] = [
        Color(red: 0.55, green: 0.66, blue: 0.96),  // low
        Color(red: 0.36, green: 0.50, blue: 0.94),  // mid
        Color(red: 0.20, green: 0.38, blue: 0.92),  // high
    ]

    private static func dateLabel(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("EEE MMMd")
        return f.string(from: date)
    }

    private static func tokensLabel(for tokens: Int) -> String {
        if tokens == 0 { return String(localized: "No activity") }
        return String(
            format: String(localized: "%@ tokens"),
            OverviewStatsCard.compactTokens(tokens))
    }
}

private struct HeatmapCell {
    let date: Date
    let tokens: Int
}

private struct HoveredHeatmapCell: Equatable {
    let col: Int
    let row: Int
    let cell: HeatmapCell
    static func == (lhs: HoveredHeatmapCell, rhs: HoveredHeatmapCell) -> Bool {
        lhs.col == rhs.col && lhs.row == rhs.row && lhs.cell.date == rhs.cell.date
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
