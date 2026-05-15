import SwiftUI

/// 浮在 `InputBarView2` 左上方的运行态指示 pill。视觉语言:
///
/// - 材质:`.barSurface` — 与 InputBar 完全一致(Liquid Glass / `.thickMaterial`
///   + 描边 + 阴影,由 macOS 版本派发)。
/// - 圆角:12pt。InputBar 是 20pt,12 = 0.6× — 落在"和谐子层级 chip"区间,既
///   显然小一级,又不会因为差距过大显得突兀。
/// - 内容:三颗小圆点呼吸 + 简短文案(`"Working"`,走 String Catalog 本地化)。
///   dot 直径 3pt、间距 4pt — 比 InputBar 的发送按钮(28pt)小一个数量级,视觉
///   重量克制。
/// - 动画:相位错开正弦呼吸,峰值从左到右流过 3 颗 dot。
///
/// 可见性由调用方传入(`isVisible`)。调用方应根据 `SessionHandle2.status` 判定
/// (responding / starting / interrupting → 显示;idle / stopped / notStarted →
/// 隐藏),让 source of truth 留在 handle 上 — pill 是纯视图,不持运行态副本。
struct LoadingPillView2: View {
    static let cornerRadius: CGFloat = 12

    var body: some View {
        HStack(spacing: 6) {
            DotsRow()
            Text(String(localized: "Working"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .barSurface(cornerRadius: Self.cornerRadius)
        .fixedSize()
    }
}

/// 三颗小圆点,峰值从左到右流过。`TimelineView(.animation)` 让 SwiftUI 按显示
/// 刷新率重绘 opacity,所有状态都从全局时间派生,无 `@State` 翻转,不怕重建。
private struct DotsRow: View {
    private let dotSize: CGFloat = 3
    private let spacing: CGFloat = 4
    private let period: Double = 1.2
    private let phaseStagger: Double = 0.18
    private let minOpacity: Double = 0.25

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: spacing) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: dotSize, height: dotSize)
                        .opacity(opacity(t: t, index: i))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// `phase = t/period - i*Δ/period` 让 index 越大相位越**小**,index 0 先到
    /// 峰(phase = 0.5),index 2 最后到 — 视觉上波峰自左向右扫过。
    /// `truncatingRemainder(dividingBy:)` 对负数返回负数,加 1 归一到 [0, 1)。
    private func opacity(t: TimeInterval, index: Int) -> Double {
        var phase = (t / period - Double(index) * phaseStagger / period)
            .truncatingRemainder(dividingBy: 1)
        if phase < 0 { phase += 1 }
        let s = (sin(phase * 2 * .pi - .pi / 2) + 1) / 2
        return minOpacity + s * (1 - minOpacity)
    }
}

#Preview {
    ZStack {
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
        LoadingPillView2()
    }
    .frame(width: 300, height: 80)
}
