import SwiftUI

/// Circular ring progress indicator. Used by the input bar's context
/// usage button — shows what fraction of the model's context window is
/// already consumed, color stepping from accent → orange → red as the
/// session nears the cap. Re-introduced after SessionHandle2 v2 migration
/// dropped the legacy chat stack.
struct ProgressRingView: View {
    var percent: Double
    var lineWidth: CGFloat = 2.0
    var size: CGFloat = 12
    var colorThresholds: [(Double, Color)] = [(70, .accentColor), (90, .orange), (100, .red)]

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(nsColor: .separatorColor), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: CGFloat(min(max(percent, 0), 100)) / 100)
                .stroke(ringColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.4), value: percent)
    }

    private var ringColor: Color {
        for (threshold, color) in colorThresholds {
            if percent < threshold { return color }
        }
        return colorThresholds.last?.1 ?? .accentColor
    }
}

#Preview {
    HStack(spacing: 16) {
        ProgressRingView(percent: 30)
        ProgressRingView(percent: 75)
        ProgressRingView(percent: 95)
    }
    .padding()
}
