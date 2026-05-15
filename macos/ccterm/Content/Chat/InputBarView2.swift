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
    /// stop 按钮按下时触发(只在 `isRunning` 为 true 显示 stop 时可点)。调用方
    /// 一般转发给 `SessionHandle2.interrupt()`。
    var onStop: () -> Void = {}
    /// 来自 handle 的运行态。true → 显示 stop 按钮;false → send 按钮 +
    /// canSend 控制 enable。`@State` 不再持本地副本,避免和 handle 漂移。
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
        // 不在外层放 accessibilityIdentifier:SwiftUI 默认会把容器的 id 传染给
        // 后代,覆盖子元素自己的 id(SendButton / StopButton / TextField 都会变
        // 成同一个 id,UI test 无法区分)。需要查询整个 bar 的 a11y root 时,可
        // 通过 .accessibilityElement(children: .contain) + .accessibilityIdentifier
        // 包裹,但当前测试只查具体子元素,无此需要。
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
        // (40 - 17)/2 ≈ 11.5：单行时上下各 11.5，刚好把 ~17pt 行高在 40pt 容器内居中
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
