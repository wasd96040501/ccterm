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
///
/// ## 为什么是协议而不是约束类?
///
/// 留空协议 = 空契约。今后需要 mount / unmount hook(attach CALayer 到
/// NSTableRowView 时机通知)可以通过 protocol extension 加 optional 方法,
/// 不需要所有 SideCar 都实现。
protocol RowSideCar: AnyObject {}

/// 默认 SideCar。无字段、无 hook。无 render 需要 GPU 资源的 component
/// 用这个(framework 的 default impl 自动生成)。
final class EmptyRowSideCar: RowSideCar {
    init() {}
}
