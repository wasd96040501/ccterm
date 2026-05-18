import SwiftUI

/// Standalone `+` button for the input bar. A single tap opens the host's
/// attachment picker (any file). The host decides how to display the
/// picked file — image files get a thumbnail preview, everything else
/// gets the Finder file icon.
///
/// Three stacked layers in a 32×32 ZStack, matching the pill's height:
///
/// 1. **Static surface** (Circle) — mirrors `InputBarView2.barSurface`:
///    - macOS 26+: `glassEffect(.regular, in: Circle())`.
///    - macOS 14/15: `.thickMaterial` (dark) / `.bar` (light), clipped
///      to a circle, with the same separator stroke as the pill.
///
/// 2. **Hover overlay** — a `Color.primary.opacity` fill driven by
///    `.onHover`. Apple Developer Forums #742966 documents
///    `.onHover { hovering in ... }` + `@State` as the recommended
///    SwiftUI pattern for hover background highlights on macOS.
///    `.borderlessButton` button style doesn't paint a hover background
///    of its own; `.hoverEffect(.highlight)` changes the *pointer* shape
///    rather than the view background — neither delivers the subtle tint
///    Apple uses for toolbar / sidebar action buttons.
///
/// 3. **Activator** on top — a transparent `Button` so the surface and
///    hover overlay show through. `.buttonStyle(.plain)` keeps it
///    chrome-less.
struct AttachButton: View {
    /// Fired when the user taps the `+`. The caller drives the
    /// `NSOpenPanel` flow so this view stays purely visual.
    var onPick: () -> Void
    /// When `true`, the surface stroke flips to accent + a dashed style to
    /// echo the pill's drop-target highlight (driver lives in `InputBarView2`).
    var isDropTargeted: Bool = false

    static let size: CGFloat = 32

    @State private var isHovered: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            surface
            hoverOverlay
            Button(action: onPick) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: Self.size, height: Self.size)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: Self.size, height: Self.size)
        .onHover { isHovered = $0 }
        .accessibilityLabel(String(localized: "Attach image or file"))
    }

    @ViewBuilder
    private var surface: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: Circle())
                .overlay {
                    Circle().stroke(strokeColor, style: strokeStyle)
                }
        } else {
            Circle()
                .fill(colorScheme == .dark ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(.bar))
                .overlay {
                    Circle().stroke(strokeColor, style: strokeStyle)
                }
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

    /// Tint strength tuned to read like the toolbar / sidebar hover state
    /// at the system's default control accent: visible against both dark
    /// (where `.primary` is white) and light (where it's near-black)
    /// schemes without overpowering the glass beneath.
    private var hoverOverlay: some View {
        Circle()
            .fill(Color.primary.opacity(isHovered ? 0.10 : 0))
            .animation(.easeOut(duration: 0.12), value: isHovered)
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
