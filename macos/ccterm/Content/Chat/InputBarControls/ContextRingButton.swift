import SwiftUI

/// Footer-row indicator: how much of the model's context window the
/// running session has used. Hidden when `contextWindowTokens` is still
/// zero (the CLI hasn't yet reported a window — usually before the first
/// `.result`). Hover surfaces the absolute counts and percentage; the
/// pill itself doesn't open a popover.
struct ContextRingButton: View {
    let handle: SessionHandle2

    var body: some View {
        if handle.contextWindowTokens > 0 {
            HStack(spacing: 5) {
                ProgressRingView(percent: percent)
                Text("\(Int(percent))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .help(tooltip)
        }
    }

    private var percent: Double {
        let used = Double(handle.contextUsedTokens)
        let total = Double(handle.contextWindowTokens)
        return min(max(used / total * 100, 0), 100)
    }

    private var tooltip: String {
        let used = formatTokens(handle.contextUsedTokens)
        let total = formatTokens(handle.contextWindowTokens)
        return "\(used) / \(total) (\(Int(percent))%)"
    }

    private func formatTokens(_ count: Int) -> String {
        let k = Double(count) / 1000.0
        return String(format: "%.1fk", k)
    }
}
