import CoreText
import Foundation

/// 固定宽度、不可见的内联 spacer——CoreText 风格。
///
/// 在 attributed string 里插一个 U+FFFC（OBJECT REPLACEMENT CHARACTER）字符，
/// 挂上一个 `CTRunDelegate` 让它的 advance 强制等于 `width` 点：
/// - **零 ink**：U+FFFC 本身没有可见字形（不渲染）
/// - **CTRunDelegate 一等公民**：U+FFFC 是 NSTextAttachment 用的那个字符，
///   CoreText 排版时**必定**调 delegate 的 getAscent/getDescent/getWidth 取几何
/// - **独立 CTRun**：CT 不会把 U+FFFC 合并进相邻 run
///
/// 不要用 U+2060（WORD JOINER）——它是 `Default_Ignorable_Code_Point=Yes`，
/// CT 会把它的字形跳过、连带挂在它上面的 CTRunDelegate / `.kern` 都被丢，
/// spacer 实际宽度变 0。
///
/// 副作用：U+FFFC 是 Line Break Class CB（Contingent Break），理论上是个断行
/// 机会。实际表现里 CT 在 chip 上下文中不太会真的折在这——但 caller 如果对
/// 折行行为敏感，需要自己确认。
///
/// 用途：给内联背景（chip / pill / tag）两侧加精确外边距，比 `.kern` 推位干净——
/// 直接说"这里要 X pt 间隙"，不用走 `kern - chipPadding` 的减法换算。
///
/// 示例：
/// ```swift
/// out.append(InlineSpacer.attributedString(width: 6))
/// out.append(chip)
/// out.append(InlineSpacer.attributedString(width: 6))
/// ```
enum InlineSpacer {

    /// 一个宽度为 `width` 的不可见 spacer。`width <= 0` 返回空串——
    /// 不能 fallback 到光秃秃的 U+FFFC：CT 会用 U+FFFC 自己的字形（一个
    /// 可见的"object replacement"占位框）渲染，反而引入可见宽度。
    static func attributedString(width: CGFloat) -> NSAttributedString {
        guard width > 0 else {
            return NSAttributedString()
        }

        // refCon: heap 一个 CGFloat，dealloc 回调里释放。CTRunDelegate 持有
        // delegate 引用，引用消失时回调被触发。
        let infoPtr = UnsafeMutablePointer<CGFloat>.allocate(capacity: 1)
        infoPtr.initialize(to: width)

        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateCurrentVersion,
            dealloc: { ptr in
                let typed = ptr.assumingMemoryBound(to: CGFloat.self)
                typed.deinitialize(count: 1)
                typed.deallocate()
            },
            getAscent: { _ in 0 },
            getDescent: { _ in 0 },
            getWidth: { ptr in
                ptr.assumingMemoryBound(to: CGFloat.self).pointee
            })

        guard let delegate = CTRunDelegateCreate(&callbacks, infoPtr) else {
            // 创建失败兜底——避免泄漏 + 不要回退到裸 U+FFFC（会渲染占位框）。
            infoPtr.deinitialize(count: 1)
            infoPtr.deallocate()
            return NSAttributedString()
        }

        return NSAttributedString(
            string: "\u{FFFC}",
            attributes: [
                NSAttributedString.Key(kCTRunDelegateAttributeName as String): delegate,
            ])
    }

}
