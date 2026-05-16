import SwiftUI

/// Running-state pill that floats above the top-left of `InputBarView2`.
///
/// - Surface: `.barSurface` — identical to InputBar (Liquid Glass /
///   `.thickMaterial` + stroke + shadow, dispatched by macOS version).
/// - Corner: 12pt. InputBar is 20pt, so 12 = 0.6× — clearly a sub-level chip,
///   visibly smaller without feeling discordant.
/// - Content: three breathing dots + short text (`"Working"`, localized via
///   String Catalog). Dot diameter 3pt, gap 4pt — an order of magnitude smaller
///   than the InputBar send button (28pt), keeping visual weight restrained.
/// - Animation: phase-staggered sine breath, peak sweeps left-to-right across
///   the three dots.
///
/// Visibility is passed in by the caller (`isVisible`). Callers should derive
/// it from `SessionHandle2.status` (responding / starting / interrupting →
/// show; idle / stopped / notStarted → hide), keeping the source of truth on
/// the handle — the pill is a pure view and holds no running-state copy.
struct LoadingPillView2: View {
    static let cornerRadius: CGFloat = 12

    var body: some View {
        HStack(spacing: 6) {
            DotsRow()
            Text(String(localized: "Working"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .barSurface(cornerRadius: Self.cornerRadius)
        .fixedSize()
    }
}

/// Three dots with the peak sweeping left-to-right. `TimelineView(.animation)`
/// has SwiftUI redraw opacity at the display refresh rate; all state is
/// derived from global time, no `@State` toggles, safe across rebuilds.
private struct DotsRow: View {
    private let dotSize: CGFloat = 3
    private let spacing: CGFloat = 4
    private let period: Double = 1.2
    private let phaseStagger: Double = 0.18
    private let minOpacity: Double = 0.25

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: spacing) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: dotSize, height: dotSize)
                        .opacity(opacity(t: t, index: i))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// `phase = t/period - i*Δ/period` makes higher index mean *smaller* phase,
    /// so index 0 hits peak first (phase = 0.5) and index 2 last — the wave
    /// crest sweeps left-to-right. `truncatingRemainder(dividingBy:)` returns
    /// negative for negatives, so +1 normalizes back into [0, 1).
    private func opacity(t: TimeInterval, index: Int) -> Double {
        var phase = (t / period - Double(index) * phaseStagger / period)
            .truncatingRemainder(dividingBy: 1)
        if phase < 0 { phase += 1 }
        let s = (sin(phase * 2 * .pi - .pi / 2) + 1) / 2
        return minOpacity + s * (1 - minOpacity)
    }
}

#Preview {
    ZStack {
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
        LoadingPillView2()
    }
    .frame(width: 300, height: 80)
}
