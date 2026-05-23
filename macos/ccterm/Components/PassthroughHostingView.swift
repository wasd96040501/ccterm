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
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        return result === self ? nil : result
    }
}
