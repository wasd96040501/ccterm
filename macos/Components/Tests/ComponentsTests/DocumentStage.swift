import AppKit

/// A view controller mounted in a window parked off screen, for the tests that
/// measure a mounted tree (the app's `AppKitStage`, which a package's tests run
/// without): the controller's view pinned to the window's edges, laid out, and a
/// runloop to drain. The window never becomes key.
@MainActor
final class DocumentStage {
    let window: NSWindow
    let rootViewController: NSViewController

    private init(window: NSWindow, rootViewController: NSViewController) {
        self.window = window
        self.rootViewController = rootViewController
    }

    static func mount(_ controller: NSViewController, size: CGSize) -> DocumentStage {
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.alphaValue = 0.01
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: container.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.makeKeyAndOrderFront(nil)
        container.layoutSubtreeIfNeeded()
        return DocumentStage(window: window, rootViewController: controller)
    }

    func teardown() {
        window.contentView = nil
        window.close()
    }

    /// Runs the loop for `seconds`, then lays the tree out once.
    func drain(seconds: TimeInterval = 0.05) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func find<T: NSView>(_ type: T.Type) -> T? { findAll(type).first }

    func findAll<T: NSView>(_ type: T.Type) -> [T] {
        var found: [T] = []
        func walk(_ view: NSView) {
            if let match = view as? T { found.append(match) }
            view.subviews.forEach(walk)
        }
        walk(rootViewController.view)
        return found
    }
}
