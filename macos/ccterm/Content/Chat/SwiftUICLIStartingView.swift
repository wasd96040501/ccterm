import SwiftUI

/// Elegant loading bar shown above input when CLI is starting up.
/// A subtle highlight band sweeps across periodically — skeleton-shimmer style.
struct SwiftUICLIStartingView: View {
    private let barHeight: CGFloat = 24
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            PulsingDot()
            Text("CLI Starting")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.leading, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: barHeight)
        .background(backgroundColor)
    }

    private var backgroundColor: Color {
        colorScheme == .dark
            ? .white.opacity(0.04)
            : .black.opacity(0.03)
    }

}

// MARK: - Pulsing Dot

private struct PulsingDot: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(.green)
            .frame(width: 7, height: 7)
            .opacity(isPulsing ? 1.0 : 0.4)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

// MARK: - Preview

#Preview("CLI Starting — in InputBar") {
    VStack(spacing: 0) {
        SwiftUICLIStartingView()
        Divider()
        Text("Input area")
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(.ultraThinMaterial)
    }
    .clipShape(RoundedRectangle(cornerRadius: 20))
    .overlay {
        RoundedRectangle(cornerRadius: 20)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
    }
    .frame(width: 600)
    .padding(40)
    .background(Color(nsColor: .windowBackgroundColor))
}
