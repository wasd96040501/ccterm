import AppKit

/// Host views waiting for a row, by `identifier` (SPEC P4).
///
/// A view without an identifier is never pooled. `makeView(withIdentifier:make:)`
/// sets one, so only views built some other way are affected.
@MainActor
final class RowViewPool {

    private var waiting: [NSUserInterfaceItemIdentifier: [NSView]] = [:]

    init() {}

    /// A pooled view with `identifier`, else `make()` with the identifier set.
    /// Stops with a precondition failure if the pooled view isn't a `V`: one
    /// identifier, one view type.
    func makeView<V: NSView>(withIdentifier identifier: NSUserInterfaceItemIdentifier, make: () -> V) -> V {
        if let view = waiting[identifier]?.popLast() {
            guard let typed = view as? V else {
                preconditionFailure(
                    "ExactList: identifier \(identifier.rawValue) pooled a \(type(of: view)), asked for a \(V.self) (P4)"
                )
            }
            return typed
        }
        let view = make()
        view.identifier = identifier
        return view
    }

    /// Takes a view back (P3).
    func enqueue(_ view: NSView) {
        guard let identifier = view.identifier else { return }
        waiting[identifier, default: []].append(view)
    }

    /// Drops every pooled view (U7).
    func removeAll() {
        waiting.removeAll()
    }
}
