import AppKit
import SwiftUI

/// `NSHostingView` subclass with an explicit "should this overlay claim
/// clicks" gate. When `claimsHits` is `false`, `hitTest(_:)` returns
/// `nil` for every point in the host's bounds — so AppKit moves on to
/// the next sibling underneath (e.g. a side-branch view like Archive)
/// rather than letting the otherwise-transparent SwiftUI body swallow
/// the click.
///
/// The previous implementation tried to derive this from
/// `super.hitTest(_:) === self`, on the theory that NSHostingView only
/// returns itself when no SwiftUI subview matches. That theory is
/// wrong: SwiftUI controls with no AppKit backing (any `Button` with
/// `.buttonStyle(.plain)`, `Menu` with `.menuStyle(.button)`, etc.)
/// also resolve to the hosting view, so the heuristic ate every click
/// on the input bar's chrome row (Permission / Model · Effort / Todo
/// / Context-ring / Attach `+`). Pinning the decision to an explicit
/// flag set by the host's controller, based on what the SwiftUI body
/// currently renders, is the only safe split.
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
    /// `true` → behave like a plain `NSHostingView` (super decides);
    /// `false` → drop every hit so the view below receives it.
    /// Default `true` is the conservative choice: a fresh host claims
    /// its bounds until the controller flips it off.
    var claimsHits: Bool = true

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard claimsHits else { return nil }
        return super.hitTest(point)
    }
}
