import SwiftUI

/// A circular ring progress indicator.
struct ProgressRingView: View {
    var percent: Double
    var lineWidth: CGFloat = 2.0
    var colorThresholds: [(Double, Color)] = [(70, .green), (90, .orange), (100, .red)]

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(nsColor: .separatorColor), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: CGFloat(min(max(percent, 0), 100)) / 100)
                .stroke(ringColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
        .animation(.easeInOut(duration: 0.4), value: percent)
    }

    private var ringColor: Color {
        // Iterate thresholds in order; first one where percent < threshold wins
        for (threshold, color) in colorThresholds {
            if percent < threshold {
                return color
            }
        }
        // If above all thresholds, use the last color
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
