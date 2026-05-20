import SwiftUI

/// Pill-style trigger button rendered in the input-bar footer row. Used
/// as the affordance for the permission-mode popover and the
/// model-and-effort popover — the label is the current selection's
/// short title, optionally accented (the permission button uses the
/// accent color so "Auto" / "Bypass" stand out even at a glance).
///
/// The button surface is the same `.barSurface` material as the main
/// pill, but at 22pt height with a smaller corner radius — matching
/// the compact density of Claude.app's compose footer.
struct BarChromeButton<Content: View>: View {
    @ViewBuilder var label: () -> Content
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .barSurface(cornerRadius: 8)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.linear(duration: 0.1), value: hovering)
    }
}
