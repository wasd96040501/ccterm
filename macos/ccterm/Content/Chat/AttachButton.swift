import SwiftUI

/// Standalone `+` button for the input bar. Opens a menu of attachment
/// types (currently just Image).
///
/// Surface and interaction state come entirely from system button styling
/// — no hand-rolled background or hover overlay:
///
/// - `.menuStyle(.button)` renders the Menu through SwiftUI's button
///   pipeline so `ButtonStyle` actually applies (the default menu style
///   ignores it).
/// - `.buttonStyle(.bordered)` paints a material chip on macOS 14/15;
///   macOS 26+ automatically promotes the same style to Liquid Glass.
///   Hover and press highlights are provided by the system in both eras.
/// - `.buttonBorderShape(.circle)` clips that surface to a circle.
///
/// Deliberately not sharing `InputBarView2`'s `barSurface` modifier — the
/// bar modifier is shaped for the rounded-rectangular pill chrome (drop
/// shadow + edge stroke sized to a large surface) and doesn't fit a
/// small circular button.
struct AttachButton: View {
    /// Fired when the user picks "Image" from the menu. The caller drives
    /// the `NSOpenPanel` flow so this view stays purely visual.
    var onPickImage: () -> Void

    private let iconPointSize: CGFloat = 13

    var body: some View {
        // SwiftUI `Menu` on macOS 26 renders as a `MenuButton` whose
        // accessibility node swallows child identifiers — putting
        // `.testIdentifier` on the Menu or its label closure is silently
        // dropped. The stable handle is `.accessibilityLabel` on the
        // Menu (sets the MenuButton's AX label); tests query
        // `app.menuButtons["Attach image or file"]`.
        Menu {
            Button(action: onPickImage) {
                Label(String(localized: "Image"), systemImage: "photo")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: iconPointSize, weight: .bold))
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(String(localized: "Attach image or file"))
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
