import Foundation

/// Value bag threaded from `MainSplitViewController` into
/// `SidebarViewController`. The sidebar counterpart of `DetailContext`:
/// collapses the four-argument imperative DI fan-out into one value, so a new
/// sidebar-scope dependency is one edit here, not a parallel change in the
/// initializer and the split's construction site.
///
/// Unlike `DetailContext`, the sidebar's dependencies are consumed
/// imperatively (the AppKit `NSOutlineView` controller reads them directly),
/// so there is no SwiftUI environment-injection counterpart — the bag is read
/// through `context.X` inside the controller.
@MainActor
struct SidebarContext {
    let model: MainSelectionModel
    let sessionManager: SessionManager
    let groupOrderStore: SidebarSessionGroupOrderStore
    let openInService: OpenInAppService
}
