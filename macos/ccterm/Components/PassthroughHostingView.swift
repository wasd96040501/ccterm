import AppKit
import SwiftUI

/// `NSHostingView` subclass with hit-test passthrough on transparent
/// SwiftUI regions. Without this override, an `NSHostingView` overlaid
/// on top of AppKit content claims every point inside its bounds for
/// hit-testing, shadowing whichever AppKit view sits below (e.g. the
/// transcript `NSTableView`).
///
/// `super.hitTest(point)` already does the work of walking SwiftUI's
/// internal subview tree: it returns the deepest SwiftUI rendering
/// view that contains the point. For transparent SwiftUI regions
/// (e.g. an empty `Spacer`) no SwiftUI subview matches, and super
/// falls back to returning the hosting view itself. We intercept that
/// fallback and return nil instead, so AppKit moves on to the next
/// sibling and the table below receives the hit.
///
/// **Concrete `AnyView` specialization on purpose.** A generic
/// `PassthroughHostingView<Content>: NSHostingView<Content>` triggers
/// a Swift 6.3 SIL inliner crash on Release builds
/// (swiftlang/swift#88173) when the compiler synthesizes the generic
/// class's `__deallocating_deinit`. Pinning `Content` to `AnyView` —
/// which is the only shape the only call site (`composeOrBarHost`)
/// uses — sidesteps the crash. If a second call site needs a
/// different `Content`, hoist this pattern into a non-generic base
/// class rather than re-introducing generics.
final class PassthroughHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        return result === self ? nil : result
    }
}
