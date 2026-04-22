import CoreText
import Foundation

/// 固定宽度、不可见、不可断行的内联 spacer——CoreText 风格。
///
/// 在 attributed string 里插一个 U+2060（WORD JOINER）字符，挂上一个
/// `CTRunDelegate` 让它的 advance 强制等于 `width` 点。三个不变式：
/// - **零 ink**：U+2060 本身没有可见字形，只占位
/// - **不可断行**：U+2060 是 Unicode "no-break"，CTTypesetter 永远不会在这里折行
/// - **独立 CTRun**：`CTRunDelegate` 这个 attribute 必然把 spacer 切成单独 run，
///   邻居 run 的 typographic bounds 完全不被影响
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

    /// 一个宽度为 `width` 的不可见 spacer。`width <= 0` 退化成纯 U+2060。
    static func attributedString(width: CGFloat) -> NSAttributedString {
        guard width > 0 else {
            return NSAttributedString(string: "\u{2060}")
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
            // 创建失败兜底——避免泄漏 + 至少返回一个 invisible joiner。
            infoPtr.deinitialize(count: 1)
            infoPtr.deallocate()
            return NSAttributedString(string: "\u{2060}")
        }

        return NSAttributedString(
            string: "\u{2060}",
            attributes: [
                NSAttributedString.Key(kCTRunDelegateAttributeName as String): delegate,
            ])
    }
}
