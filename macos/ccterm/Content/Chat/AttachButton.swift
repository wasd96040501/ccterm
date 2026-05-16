import SwiftUI

/// Standalone `+` button for the input bar. Opens a menu of attachment
/// types (Image today; structured as a `Menu` so future types — Files,
/// snippets, etc. — drop in without restructuring this view).
///
/// Visuals come entirely from system button styling — no hand-painted
/// background, no manual hover overlay:
///
/// - `.menuStyle(.button)` routes the Menu's activator through the
///   button render pipeline so `ButtonStyle` actually applies. The
///   default menu style ignores `.buttonStyle`.
/// - macOS 26+: `.buttonStyle(.glass)` renders Liquid Glass with the
///   system's built-in hover / press response. `.bordered` does *not*
///   auto-promote to LG on 26 — `.glass` is the only style that does.
/// - macOS 14/15: `.buttonStyle(.bordered)` paints a material chip with
///   the system's built-in hover / press response.
/// - `.buttonBorderShape(.circle)` clips the surface to a circle.
/// - `.controlSize(.large)` brings the natural button height close to
///   `InputBarView2.pillMinHeight` (32pt) so the two read as one row
///   under the parent HStack's `.center` alignment.
struct AttachButton: View {
    /// Fired when the user picks "Image" from the menu. The caller drives
    /// the `NSOpenPanel` flow so this view stays purely visual.
    var onPickImage: () -> Void

    var body: some View {
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
        }
        .modifier(AttachButtonSurface())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(String(localized: "Attach image or file"))
    }
}

private struct AttachButtonSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .menuStyle(.button)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
        } else {
            content
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.large)
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
