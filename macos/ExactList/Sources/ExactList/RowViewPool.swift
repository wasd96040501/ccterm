import AppKit

/// Host views waiting for a row, by `identifier` (SPEC P4).
///
/// A view without an identifier is never pooled. `makeView(withIdentifier:make:)`
/// sets one, so only views built some other way are affected.
@MainActor
final class RowViewPool {

    init() {
        fatalError("unimplemented: SPEC P4")
    }

    /// A pooled view with `identifier`, else `make()` with the identifier set.
    /// Stops with a precondition failure if the pooled view isn't a `V`: one
    /// identifier, one view type.
    func makeView<V: NSView>(withIdentifier identifier: NSUserInterfaceItemIdentifier, make: () -> V) -> V {
        fatalError("unimplemented: SPEC P4")
    }

    /// Takes a view back (P3).
    func enqueue(_ view: NSView) {
        fatalError("unimplemented: SPEC P3")
    }

    /// Drops every pooled view (U7).
    func removeAll() {
        fatalError("unimplemented: SPEC U7")
    }
}
