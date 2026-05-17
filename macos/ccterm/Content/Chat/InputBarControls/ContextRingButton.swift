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
    let handle: SessionHandle2
    @State private var isPresented = false

    var body: some View {
        Button(action: { isPresented.toggle() }) {
            ProgressRingView(percent: percent)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            ContextPopoverContent(
                used: handle.contextUsedTokens,
                total: handle.contextWindowTokens,
                percent: percent
            )
        }
        .accessibilityLabel(String(localized: "Context usage"))
        .accessibilityValue("\(Int(percent))%")
    }

    private var percent: Double {
        let total = Double(handle.contextWindowTokens)
        guard total > 0 else { return 0 }
        let used = Double(handle.contextUsedTokens)
        return min(max(used / total * 100, 0), 100)
    }
}

private struct ContextPopoverContent: View {
    let used: Int
    let total: Int
    let percent: Double

    var body: some View {
        VStack(spacing: 0) {
            PopoverSectionHeader(title: String(localized: "Context"))
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
            .padding(.horizontal, PopoverList.horizontalInset)
            .padding(.top, 2)
            .padding(.bottom, 6)
        }
        .padding(PopoverList.outerPadding)
        .frame(width: PopoverList.width)
    }

    private var usageLine: String {
        "\(formatTokens(used)) / \(formatTokens(total))"
    }

    private var percentLine: String {
        String(format: String(localized: "%lld%% used"), Int(percent))
    }

    private func formatTokens(_ count: Int) -> String {
        let k = Double(count) / 1000.0
        return String(format: "%.1fk", k)
    }
}
