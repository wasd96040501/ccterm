import SwiftUI

/// V2 输入栏（仅 UI，不接入 session handle）。
///
/// 布局：squircle 容器 + `HStack(text, sendButton)`。空 / 单行时容器高度 = `2 *
/// cornerRadius`（40pt）。发送按钮与右下角同心：corner radius 20，button radius
/// 14，共享圆心 ⇒ 距右 / 下 6pt。Cmd+Return 发送 → 图标切换为 stop；Esc 取消 →
/// 回到发送态。
struct InputBarView2: View {
    static let cornerRadius: CGFloat = 20
    private let buttonSize: CGFloat = 28
    private let buttonInset: CGFloat = 6
    private let animationDuration: TimeInterval = 0.35

    /// 由调用方注入。仅在 `canSend` 为 true 时被触发(空白文字不会调用)。
    var onSubmit: (String) -> Void = { _ in }

    @State private var text: String = ""
    @State private var isResponding: Bool = false
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
        .animation(.smooth(duration: animationDuration), value: isResponding)
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
            onEscape: { handleStop() },
            isFocused: $isFocused,
            desiredCursorPosition: $desiredCursorPosition
        )
        .padding(.leading, 16)
        .padding(.trailing, 4)
        // (40 - 17)/2 ≈ 11.5：单行时上下各 11.5，刚好把 ~17pt 行高在 40pt 容器内居中
        .padding(.vertical, 11.5)
    }

    // MARK: - Send / Stop Button

    @ViewBuilder
    private var sendOrStopButton: some View {
        if isResponding {
            circleButton(
                icon: "stop.fill",
                color: Color(nsColor: .systemGray),
                action: handleStop
            )
            .transition(.scale.combined(with: .opacity))
        } else {
            circleButton(
                icon: "arrow.up",
                color: .accentColor,
                action: handleSend
            )
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
        isResponding = true
    }

    private func handleStop() {
        isResponding = false
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

/// macOS 26+ → Liquid Glass(`glassEffect(_:in:)`,系统提供半透明 + 边缘高光 +
/// 折射)。低于 26 → dark `.thickMaterial` / light `.bar` + 描边 + 阴影。
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
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.12),
                        radius: 12, x: 0, y: 4)
        } else {
            content
                .background(colorScheme == .dark ? .thickMaterial : .bar)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
                .shadow(color: colorScheme == .light ? .black.opacity(0.1) : .clear,
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
