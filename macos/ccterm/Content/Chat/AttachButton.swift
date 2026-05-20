import SwiftUI

/// Standalone `+` button for the input bar. Clicking pops a single-item
/// SwiftUI `Menu` — "Attach Image or File" — which then drives the host's
/// `NSOpenPanel` flow. The host decides how to display the picked file —
/// image files get a thumbnail preview, everything else gets the Finder
/// file icon.
///
/// Structure:
///
/// - `Menu { ... } label: { ... }` provides the popup behaviour.
/// - `.menuStyle(.button)` + `.buttonStyle(.plain)` — the built-in `.plain`
///   style handles press feedback natively (icon dims while pressed), so
///   we don't write any hover/press code ourselves.
/// - The glass / material circle + stroke live inside the label as a
///   `.background`, so they stay solid while `.plain` dims the icon.
/// - `.menuIndicator(.hidden)` drops the trailing chevron.
struct AttachButton: View {
    /// Fired when the user picks the "Attach Image or File" menu item.
    /// The caller drives the `NSOpenPanel` flow so this view stays
    /// purely visual.
    var onPick: () -> Void
    /// When `true`, the surface stroke flips to accent + a dashed style to
    /// echo the pill's drop-target highlight (driver lives in `InputBarView2`).
    var isDropTargeted: Bool = false

    static let size: CGFloat = 32

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Menu {
            Button(action: onPick) {
                Label(
                    String(localized: "Attach Image or File"),
                    systemImage: "paperclip"
                )
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: AttachButton.size, height: AttachButton.size)
                .background {
                    ZStack {
                        surface
                        Circle()
                            .stroke(strokeColor, style: strokeStyle)
                    }
                }
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(String(localized: "Attach image or file"))
    }

    @ViewBuilder
    private var surface: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: Circle())
        } else {
            Circle()
                .fill(colorScheme == .dark ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(.bar))
        }
    }

    private var strokeColor: Color {
        isDropTargeted ? Color.accentColor : Color(nsColor: .separatorColor)
    }

    private var strokeStyle: StrokeStyle {
        isDropTargeted
            ? StrokeStyle(lineWidth: 1.5, dash: [4, 3])
            : StrokeStyle(lineWidth: 0.5)
    }
}

#Preview {
    ZStack {
        Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
        AttachButton(onPick: {})
            .padding(40)
    }
    .frame(width: 200, height: 120)
}
