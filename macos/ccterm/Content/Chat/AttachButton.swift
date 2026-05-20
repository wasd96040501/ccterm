import SwiftUI

/// Standalone `+` button for the input bar. Clicking pops a single-item
/// SwiftUI `Menu` — "Attach Image or File" — which then drives the host's
/// `NSOpenPanel` flow. The host decides how to display the picked file —
/// image files get a thumbnail preview, everything else gets the Finder
/// file icon.
///
/// Structure mirrors `NewSessionConfigurator.worktreeMenu` + `HoverCapsuleStyle`:
///
/// - `Menu { ... } label: { ... }` provides the popup behaviour.
/// - `.menuStyle(.button)` lets a custom `ButtonStyle` sit underneath.
/// - `.menuIndicator(.hidden)` drops the trailing chevron.
/// - `.buttonStyle(AttachCircleStyle(...))` reads `configuration.isPressed`
///   and tints the whole 32pt `Circle()`, so press feedback covers the full
///   disc — and stays on while the menu is open, because SwiftUI keeps
///   `isPressed = true` for the menu's lifetime.
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
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(
            AttachCircleStyle(
                isDropTargeted: isDropTargeted,
                colorScheme: colorScheme
            )
        )
        .fixedSize()
        .accessibilityLabel(String(localized: "Attach image or file"))
    }
}

/// `ButtonStyle` for `AttachButton`. Delegates the actual visuals to
/// `AttachCircleModifier` so `@State` (hover) lives in a real `View`
/// context — `ButtonStyle` is not a `View`, so a `@State` declared on
/// the style itself wouldn't get SwiftUI storage. Same pattern as
/// `HoverCapsuleStyle` / `HoverCapsuleModifier`.
private struct AttachCircleStyle: ButtonStyle {
    let isDropTargeted: Bool
    let colorScheme: ColorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(
                AttachCircleModifier(
                    isDropTargeted: isDropTargeted,
                    colorScheme: colorScheme,
                    isPressed: configuration.isPressed
                )
            )
    }
}

private struct AttachCircleModifier: ViewModifier {
    let isDropTargeted: Bool
    let colorScheme: ColorScheme
    let isPressed: Bool

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .frame(width: AttachButton.size, height: AttachButton.size)
            .background {
                ZStack {
                    surface
                    Circle()
                        .fill(Color(nsColor: .labelColor).opacity(stateOpacity))
                    Circle()
                        .stroke(strokeColor, style: strokeStyle)
                }
            }
            .contentShape(Circle())
            .onHover { isHovered = $0 }
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

    /// Press opacity matches `HoverCapsuleStyle.pressOpacity` (0.15); hover
    /// uses the same hoverOpacity (0.08) for consistency with the worktree /
    /// branch pills. Press wins over hover when both are active.
    private var stateOpacity: Double {
        if isPressed { return 0.15 }
        if isHovered { return 0.08 }
        return 0
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
