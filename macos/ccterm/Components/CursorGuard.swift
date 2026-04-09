import AppKit

/// 全局 cursor 守卫。通过 swizzle `NSCursor.set()` 拦截 WKWebView 的异步 cursor 更新。
///
/// WKWebView 通过内部 IPC 直接调用 `NSCursor.set()`，绕过 AppKit 的 cursor rect
/// 和 cursorUpdate 系统。标准的 overlay、resetCursorRects、cursorUpdate 均无法拦截。
///
/// 本方案在 `NSCursor.set()` 入口处拦截：
/// 1. 如果鼠标在已注册的 guard rect 内 → 强制 arrow cursor
/// 2. 如果鼠标在已注册的 text input view 上且 cursor 被设为 arrow → 修正为 I-beam
/// 3. 其他情况 → 放行
///
/// swizzle 在 `install()` 时安装一次。guard rect 和 text input view 均通过 registry 动态注册/注销。
enum CursorGuard {

    // MARK: - Registry

    private static var lock = os_unfair_lock()
    private static var entries: [ObjectIdentifier: Entry] = [:]
    private static var textInputViews: [ObjectIdentifier: WeakView] = [:]
    private static var installed = false

    struct Entry {
        weak var view: NSView?
        var rects: [CGRect]  // view 本地坐标系（flipped, origin 左上角）
    }

    struct WeakView {
        weak var view: NSView?
    }

    /// 安装 swizzle。应用启动时调用一次。
    static func install() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard !installed else { return }
        installSwizzle()
        installed = true
    }

    /// 注册 guard rects。
    static func register(_ view: NSView, rects: [CGRect]) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        entries[ObjectIdentifier(view)] = Entry(view: view, rects: rects)
    }

    /// 移除注册。
    static func unregister(_ view: NSView) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        entries.removeValue(forKey: ObjectIdentifier(view))
    }

    /// 注册需要 I-beam 光标修正的 text input view。
    static func registerTextInput(_ view: NSView) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        textInputViews[ObjectIdentifier(view)] = WeakView(view: view)
    }

    /// 移除 text input view 注册。
    static func unregisterTextInput(_ view: NSView) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        textInputViews.removeValue(forKey: ObjectIdentifier(view))
    }

    // MARK: - Swizzle

    private static func installSwizzle() {
        let original = class_getInstanceMethod(NSCursor.self, #selector(NSCursor.set))!
        let swizzled = class_getInstanceMethod(NSCursor.self, #selector(NSCursor.cursorGuard_set))!
        method_exchangeImplementations(original, swizzled)
    }

    // MARK: - Hit Test

    /// 鼠标是否在任意已注册的 guard rect 内。
    fileprivate static func isMouseInGuardRect() -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        let mouseInWindow = window.mouseLocationOutsideOfEventStream

        os_unfair_lock_lock(&lock)
        let snapshot = entries.values
        os_unfair_lock_unlock(&lock)

        for entry in snapshot {
            guard let view = entry.view, view.window === window else { continue }
            let localPoint = view.convert(mouseInWindow, from: nil)
            for rect in entry.rects {
                let effective = rect.isInfinite ? view.bounds : rect
                if effective.contains(localPoint) {
                    return true
                }
            }
        }
        return false
    }

    /// 鼠标是否在任意已注册的 text input view 上。
    fileprivate static func isMouseOverTextInput() -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        let mouseInWindow = window.mouseLocationOutsideOfEventStream

        os_unfair_lock_lock(&lock)
        let snapshot = textInputViews.values
        os_unfair_lock_unlock(&lock)

        for entry in snapshot {
            guard let view = entry.view, view.window === window else { continue }
            let localPoint = view.convert(mouseInWindow, from: nil)
            if view.bounds.contains(localPoint) {
                return true
            }
        }
        return false
    }
}

// MARK: - NSCursor Swizzle

extension NSCursor {
    @objc func cursorGuard_set() {
        // 1. Guard rect 内：强制 arrow
        if CursorGuard.isMouseInGuardRect() {
            if self != NSCursor.arrow {
                NSCursor.arrow.cursorGuard_set()
            } else {
                cursorGuard_set()  // 调原始 set()
            }
            return
        }
        // 2. InputTextView 上：arrow → I-beam
        if self == NSCursor.arrow, CursorGuard.isMouseOverTextInput() {
            NSCursor.iBeam.cursorGuard_set()
            return
        }
        // 3. 放行
        cursorGuard_set()
    }
}
