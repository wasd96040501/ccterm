import AppKit

/// A specimen's view that shows view controllers' views. Whoever holds the
/// host adopts them (`addChild`) — the page for a host in a specimen's tree, a
/// pane for the host it holds — so they appear and disappear with the page,
/// as the app's controller tree does for them.
protocol ControllerHost: NSView {
    /// The controllers whose views it shows.
    var controllers: [NSViewController] { get }
}

extension NSView {
    /// The hosts in this view's tree, itself included, and not the ones inside
    /// them: a host's own controllers adopt what they show.
    var controllerHosts: [ControllerHost] {
        if let host = self as? ControllerHost { return [host] }
        return subviews.flatMap(\.controllerHosts)
    }
}

extension NSViewController {
    /// Adopts the controllers of every host in `view`'s tree.
    func adoptControllers(shownIn view: NSView) {
        for host in view.controllerHosts {
            for controller in host.controllers { addChild(controller) }
        }
    }
}
