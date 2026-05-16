import SwiftUI

/// Standalone `+` button for the input bar. Opens a menu of attachment
/// types (Image today; structured as a `Menu` so future types — Files,
/// snippets, etc. — drop in without restructuring this view).
///
/// Layered like InputBarView2, sized to match the pill's 32pt height:
///
/// - **Static surface** (Circle) drawn underneath, mirroring
///   `InputBarView2.barSurface`:
///   - macOS 26+: `glassEffect(.regular, in: Circle())` — same Liquid
///     Glass as the pill, just clipped to a circle.
///   - macOS 14/15: `.thickMaterial` (dark) / `.bar` (light) clipped to
///     a circle, with the same separator stroke as the pill.
///   No shadow — the bar's drop shadow already lifts the whole row;
///   shadowing a 32pt circle on top of that reads as soot.
///
/// - **Menu activator** stacked on top via ZStack:
///   `.menuStyle(.borderlessButton)` is transparent at rest (the surface
///   below shows through) and the system paints a hover/press highlight
///   on its own activator chrome. `.clipShape(Circle())` keeps that
///   built-in highlight inside the circular surface so it doesn't bleed
///   into the corners of the 32x32 frame.
///
/// Outer `.frame(width: 32, height: 32)` is what actually pins the
/// rendered diameter — `.fixedSize()` alone wasn't enough because
/// `.borderlessButton` menu activators don't always honor inner label
/// frames on macOS 26.
struct AttachButton: View {
    /// Fired when the user picks "Image" from the menu. The caller drives
    /// the `NSOpenPanel` flow so this view stays purely visual.
    var onPickImage: () -> Void

    static let size: CGFloat = 32

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            surface
            // SwiftUI `Menu` on macOS 26 renders as a `MenuButton` whose
            // accessibility node swallows child identifiers. The stable
            // handle is `.accessibilityLabel` on the Menu (sets the
            // MenuButton's AX label); tests query
            // `app.menuButtons["Attach image or file"]`.
            Menu {
                Button(action: onPickImage) {
                    Label(String(localized: "Image"), systemImage: "photo")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: Self.size, height: Self.size)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .clipShape(Circle())
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityLabel(String(localized: "Attach image or file"))
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
}

#Preview {
    ZStack {
        Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
        AttachButton(onPickImage: {})
            .padding(40)
    }
    .frame(width: 200, height: 120)
}
