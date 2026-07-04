import Foundation

/// Value bag threaded from `MainSplitViewController` into
/// `SidebarViewController`. The sidebar counterpart of `DetailContext`:
/// collapses the imperative DI fan-out into one value, so a new
/// sidebar-scope dependency is one edit here, not a parallel change in
/// the initializer and the split's construction site.
///
/// The delegate that receives semantic sidebar events (which selection
/// the user clicked) is intentionally NOT stored on this bag — it
/// arrives as a separate weak `init` argument to
/// `SidebarViewController`, because a `struct` can't carry a `weak var`
/// and the compiler-checked weakness is worth the extra parameter.
@MainActor
struct SidebarContext {
    /// Window-scope selection Store the sidebar subscribes to for its
    /// **model→view highlight-restore path** (Combine `@Published`).
    /// It is NEVER written by the sidebar itself — sidebar mutations
    /// flow up through the `SidebarSelectionDelegate` to the coordinator,
    /// which then writes the store. This one-way discipline is what
    /// keeps the store from becoming a routing bus.
    let selectionStore: SelectionStore
    let sessionManager: SessionManager
    let groupOrderStore: SidebarSessionGroupOrderStore
    let openInService: OpenInAppService
}
