/// 逃生门协议 —— row 需要持有 `NSObject` ref(`CALayer` / `CVDisplayLink` /
/// animation timeline / 自定义 tracking area 等 GPU/系统资源)时,component
/// 关联一个 `SideCar` class,framework per-row 持有一个实例。
///
/// 默认 `EmptyRowSideCar`:无状态、无生命周期 hook,适合绝大多数 component
/// (纯 CGContext 绘制即可)。
///
/// 需要 GPU 资源的 component 自己定义:
///
///     final class MyComponentSideCar: RowSideCar {
///         var gpuLayer: CAMetalLayer?
///         var animationTimer: CVDisplayLink?
///     }
///
///     enum MyComponent: TranscriptComponent {
///         typealias SideCar = MyComponentSideCar
///         static func makeSideCar(for content: Content) -> MyComponentSideCar {
///             MyComponentSideCar()
///         }
///         // ... render/interactions 里通过 `context.sideCar()` 访问
///     }
///
/// ## 生命周期
///
/// - Framework 在 row 首次构造时调 `C.makeSideCar(for: content)` 生成实例
/// - Row 的 stableId 不变、content 变时(carry-over)SideCar 实例保留
/// - Row 被 diff 掉(stableId 消失)时 SideCar 随 row 释放
/// - SideCar mount / unmount 到 `rowView.layer` 时,framework 调
///   `sideCarDidMount(in:)` / `sideCarWillUnmount(from:)` 通知 ——
///   addSublayer / removeFromSuperlayer 各类 CA 资源挂这里
///
/// ## 坐标系
///
/// `rowView.layer` 是 AppKit 管理的主 layer(`contentsScale` 自动跟
/// backingScale,不用手管)。rowView 的 bounds 是全窗口宽的 row,而 component
/// 的 `render(bounds:)` 用的是"内容列局部坐标"(0 = 居中列最左)——
/// rowView.draw 里 `ctx.translateBy(x: inset)` 平移画布做到这一点。
///
/// SideCar sublayer 直接挂 rowView.layer **不经过** 这个 translate,所以 frame.x
/// 必须自己加 `inset`。framework 在每次 render 前通过 `applyColumnXOffset(_:)`
/// 通知最新 inset,SideCar 在 `sync` 时把 sublayer frame 原点统一加上去。
///
/// 这样做的好处:不新建 CALayer 容器(手动创建的 CALayer 默认 `contentsScale = 1`,
/// Retina 会糊),不用 SideCar 感知 backing scale,一条 CGFloat offset 传参就够。
import AppKit
import QuartzCore

/// 默认实现为空 —— 不需要 mount hook 的 component(`EmptyRowSideCar` 等)不需要 override。
protocol RowSideCar: AnyObject {
    /// rowView.layer 挂载(新 row data 进入 reused rowView)后调用。
    /// CALayer 子图层应在这里 `rowLayer.addSublayer(myLayer)`。
    @MainActor func sideCarDidMount(in rowLayer: CALayer)

    /// Row 换 row 或被 reuse 前调用。
    /// CALayer / CA 动画应在这里 `removeFromSuperlayer` / `removeAllAnimations`。
    @MainActor func sideCarWillUnmount(from rowLayer: CALayer)

    /// Framework 在每次 render 前告知 SideCar 当前居中列的 inset(rowView 坐标系
    /// 下内容列最左的 x)。SideCar 在 `sync` 时把 sublayer.frame.origin.x 加这个
    /// offset —— 让 CA 路径和 CGContext 路径(后者靠 ctx.translateBy)看到同一
    /// 内容列起点。值变化才有必要重排 sublayer frame。
    @MainActor func applyColumnXOffset(_ xOffset: CGFloat)
}

extension RowSideCar {
    @MainActor func sideCarDidMount(in rowLayer: CALayer) {}
    @MainActor func sideCarWillUnmount(from rowLayer: CALayer) {}
    @MainActor func applyColumnXOffset(_ xOffset: CGFloat) {}
}

/// 默认 SideCar。无字段、无 hook。无 render 需要 GPU 资源的 component
/// 用这个(framework 的 default impl 自动生成)。
final class EmptyRowSideCar: RowSideCar {
    init() {}
    /// 绕过 macOS 26 SDK `swift_task_deinitOnExecutorImpl` 的 libmalloc 崩溃,
    /// 同 `TranscriptPrepareCache.deinit` 的处理。SideCar 释放无需 actor hop。
    nonisolated deinit { }
}
