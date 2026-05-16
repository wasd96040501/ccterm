import AppKit

/// Global cursor guard. Swizzles `NSCursor.set()` to intercept WKWebView's
/// asynchronous cursor updates.
///
/// WKWebView invokes `NSCursor.set()` directly over internal IPC, bypassing
/// AppKit's cursor rect and cursorUpdate machinery. Standard overlays,
/// `resetCursorRects`, and `cursorUpdate` cannot intercept it.
///
/// This implementation intercepts at `NSCursor.set()` entry:
/// 1. If the mouse is inside any registered guard rect → force arrow cursor
/// 2. If over a registered text input view and the cursor is being set to
///    arrow → correct to I-beam
/// 3. Otherwise → pass through
///
/// The swizzle is installed once via `install()`. Guard rects and text input
/// views register/unregister dynamically through the registry.
enum CursorGuard {

    // MARK: - Registry

    private static var lock = os_unfair_lock()
    private static var entries: [ObjectIdentifier: Entry] = [:]
    private static var textInputViews: [ObjectIdentifier: WeakView] = [:]
    private static var installed = false

    struct Entry {
        weak var view: NSView?
        var rects: [CGRect]  // view-local coords (flipped, origin top-left)
    }

    struct WeakView {
        weak var view: NSView?
    }

    /// Install the swizzle. Call once at app launch.
    static func install() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard !installed else { return }
        installSwizzle()
        installed = true
    }

    static func register(_ view: NSView, rects: [CGRect]) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        entries[ObjectIdentifier(view)] = Entry(view: view, rects: rects)
    }

    static func unregister(_ view: NSView) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        entries.removeValue(forKey: ObjectIdentifier(view))
    }

    /// Register a text input view that needs I-beam cursor correction.
    static func registerTextInput(_ view: NSView) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        textInputViews[ObjectIdentifier(view)] = WeakView(view: view)
    }

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

    /// True if the mouse is inside any registered guard rect.
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

    /// True if the mouse is over any registered text input view.
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
        // 1. Inside guard rect: force arrow
        if CursorGuard.isMouseInGuardRect() {
            if self != NSCursor.arrow {
                NSCursor.arrow.cursorGuard_set()
            } else {
                cursorGuard_set()  // calls the original set() (post-swizzle)
            }
            return
        }
        // 2. Over an InputTextView: arrow → I-beam
        if self == NSCursor.arrow, CursorGuard.isMouseOverTextInput() {
            NSCursor.iBeam.cursorGuard_set()
            return
        }
        // 3. Pass through
        cursorGuard_set()
    }
}
