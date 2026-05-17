import SwiftUI

/// Standalone `+` button for the input bar. Opens a menu of attachment
/// types (Image today; structured as a `Menu` so future types — Files,
/// snippets, etc. — drop in without restructuring this view).
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
///    `.borderlessButton` menu style doesn't paint a hover background
///    of its own on macOS 26, and `.hoverEffect(.highlight)` changes
///    the *pointer* shape rather than the view background — neither
///    delivers the "subtle tint under the symbol on hover" Apple uses
///    for toolbar / sidebar action buttons.
///
/// 3. **Menu activator** on top — transparent at rest so the surface
///    and hover overlay show through. `.menuStyle(.borderlessButton)`
///    + `.menuIndicator(.hidden)` keeps it chrome-less.
struct AttachButton: View {
    /// Fired when the user picks "Image" from the menu. The caller drives
    /// the `NSOpenPanel` flow so this view stays purely visual.
    var onPickImage: () -> Void
    /// Diameter. Default matches the legacy stand-alone use (a 32pt
    /// circle anchored next to the pill); the input-bar footer drops it
    /// to 22pt to sit alongside the other chrome controls.
    var size: CGFloat = 32

    @State private var isHovered: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            surface
            hoverOverlay
            // SwiftUI `Menu` on macOS 26 renders as a `MenuButton` whose
            // accessibility node swallows child identifiers. The stable
            // handle is `.accessibilityLabel` on the Menu; tests query
            // `app.menuButtons["Attach image or file"]`.
            Menu {
                Button(action: onPickImage) {
                    Label(String(localized: "Image"), systemImage: "photo")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: size, height: size)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .frame(width: size, height: size)
        .onHover { isHovered = $0 }
        .accessibilityLabel(String(localized: "Attach image or file"))
    }

    private var iconSize: CGFloat {
        max(10, size * 0.5)
    }

    @ViewBuilder
    private var surface: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: Circle())
                .overlay {
                    Circle().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
        } else {
            Circle()
                .fill(colorScheme == .dark ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(.bar))
                .overlay {
                    Circle().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
        }
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
        AttachButton(onPickImage: {})
            .padding(40)
    }
    .frame(width: 200, height: 120)
}
