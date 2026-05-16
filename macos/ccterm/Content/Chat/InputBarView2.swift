import SwiftUI

/// V2 input bar (UI only, no session handle wiring).
///
/// Layout: squircle container + `HStack(text, sendButton)`. Empty / single line
/// → container height = `2 * cornerRadius` (40pt). The send button is concentric
/// with the bottom-right corner: corner radius 20, button radius 14, shared
/// center ⇒ 6pt from the right / bottom. Cmd+Return sends → icon swaps to stop;
/// Esc cancels → back to send.
struct InputBarView2: View {
    static let cornerRadius: CGFloat = 20
    private let buttonSize: CGFloat = 28
    private let buttonInset: CGFloat = 6
    private let animationDuration: TimeInterval = 0.35

    /// Injected by the caller. Only fired when `canSend` is true (whitespace-
    /// only text won't trigger it).
    var onSubmit: (String) -> Void = { _ in }
    /// Fired when the stop button is pressed (only clickable while `isRunning`
    /// shows stop). Callers typically forward to `SessionHandle2.interrupt()`.
    var onStop: () -> Void = {}
    /// Running state from the handle. true → show stop button; false → send
    /// button gated by `canSend`. No local `@State` copy — avoids drift from
    /// the handle.
    var isRunning: Bool = false

    @State private var text: String = ""
    @State private var isFocused: Bool = false
    @State private var desiredCursorPosition: Int?

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            textArea
            sendOrStopButton
                .padding(.trailing, buttonInset)
                .padding(.bottom, buttonInset)
        }
        .frame(minHeight: 2 * Self.cornerRadius)
        .modifier(BarSurface(cornerRadius: Self.cornerRadius))
        .animation(.smooth(duration: animationDuration), value: isRunning)
        // Do not put `accessibilityIdentifier` on the outer container: SwiftUI
        // propagates the container's id to descendants by default, overriding
        // each child's own id (SendButton / StopButton / TextField would all
        // collapse to the same id, defeating UI tests). To query the whole bar
        // as an a11y root, wrap with .accessibilityElement(children: .contain)
        // + .accessibilityIdentifier — current tests only query specific
        // children, so it's not needed.
    }

    // MARK: - Text Area

    private var textArea: some View {
        TextInputView(
            text: $text,
            isEnabled: true,
            placeholder: String(localized: "Send a message"),
            font: .systemFont(ofSize: 14),
            minLines: 1,
            maxLines: 10,
            onCommandReturn: { handleSend() },
            onEscape: { if isRunning { onStop() } },
            isFocused: $isFocused,
            desiredCursorPosition: $desiredCursorPosition
        )
        .accessibilityIdentifier("InputBar2.TextField")
        .padding(.leading, 16)
        .padding(.trailing, 4)
        // (40 - 17)/2 ≈ 11.5: single-line case, 11.5 top + bottom centers the
        // ~17pt line height within the 40pt container.
        .padding(.vertical, 11.5)
    }

    // MARK: - Send / Stop Button

    @ViewBuilder
    private var sendOrStopButton: some View {
        if isRunning {
            circleButton(
                icon: "stop.fill",
                color: Color(nsColor: .systemGray),
                action: onStop
            )
            .accessibilityIdentifier("InputBar2.StopButton")
            .transition(.scale.combined(with: .opacity))
        } else {
            circleButton(
                icon: "arrow.up",
                color: .accentColor,
                action: handleSend
            )
            .accessibilityIdentifier("InputBar2.SendButton")
            .opacity(canSend ? 1.0 : 0.4)
            .disabled(!canSend)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func handleSend() {
        guard canSend else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        onSubmit(trimmed)
        text = ""
    }

    // MARK: - Helpers

    private func circleButton(icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: buttonSize, height: buttonSize)
                .background(Circle().fill(color))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Bar Surface

/// macOS 26+ → Liquid Glass (`glassEffect(_:in:)`, system-provided translucency
/// + edge highlight + refraction). Below 26 → dark `.thickMaterial` / light
/// `.bar` + stroke + shadow.
///
/// Reference: <https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:isenabled:)>
private struct BarSurface: ViewModifier {
    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
                .compositingGroup()
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.3 : 0.12),
                    radius: 12, x: 0, y: 4)
        } else {
            content
                .background(colorScheme == .dark ? .thickMaterial : .bar)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
                .shadow(
                    color: colorScheme == .light ? .black.opacity(0.1) : .clear,
                    radius: 8, x: 0, y: 1)
        }
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()

        VStack(spacing: 0) {
            Spacer(minLength: 0)
            InputBarView2()
                .frame(width: 640)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
    }
    .frame(width: 800, height: 600)
}
