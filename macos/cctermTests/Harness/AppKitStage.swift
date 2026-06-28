import AppKit

@testable import ccterm

/// Off-screen mount + runloop-control scaffold for AppKit verification
/// tests. The single entry point for standing up a **real** view tree
/// (real `MainSplitViewController` → real `SidebarViewController` +
/// real `DetailRouterViewController` + real `SessionManager`, or any
/// other production `NSViewController`) in a headless window, then
/// sampling its geometry / driving interactions / probing animation.
///
/// Why a harness and not ad-hoc per test: every AppKit verification test
/// before this re-implemented the same four things inline — build an
/// `alphaValue = 0.01` off-screen window, pin the VC's view to its
/// edges, `layoutSubtreeIfNeeded`, and hand-roll a `RunLoop.main.run`
/// drain loop. `AppKitStage` owns all four so a new test is "pick a
/// factory, `find` the subview, assert with `Geometry` / drive with
/// `InteractionDriver`."
///
/// ## Real objects only
///
/// The factories assemble production types with **in-memory, per-stage**
/// dependencies (a fresh `InMemorySessionRepository`, a `UserDefaults`
/// suite keyed on a UUID, a temp `InputDraftStore` directory). That
/// keeps every stage parallel-safe (see `cctermTests/CLAUDE.md`) while
/// still exercising the real `SessionManager` / sidebar / router wiring
/// — nothing is mocked at the controller layer.
///
/// ## What it cannot observe (off-screen / non-key-window limits)
///
/// The window sits at `(-30_000, -30_000)` with `alphaValue = 0.01` and
/// never becomes key. So anything gated on a key window or a live
/// hardware event stream is out of reach: `NSTrackingArea` hover
/// (`.activeInKeyWindow`), selection-highlight key-window tinting,
/// cursor flashing, and the real `NSApp.nextEvent(.eventTracking)` drag
/// loop (`InteractionDriver` pre-posts events to approximate it). This
/// harness is a geometry / layout / animation-curve / hit-test
/// regression gate, not an end-to-end UI automation replacement. See
/// `Harness/CLAUDE.md`.
@MainActor
final class AppKitStage {

    // MARK: - Sizes (sourced from production, not magic numbers)

    /// The main window's first-launch content size — the baseline most
    /// users run at. Source: `MainWindowController.init` `contentRect`
    /// (`1200 × 860`). Default for every factory so "this component in a
    /// real-sized window" is the zero-config case.
    static let defaultWindowSize = CGSize(width: 1200, height: 860)

    /// The main window's minimum content size. Source:
    /// `MainWindowController` `window.minSize` (`880 × 540`). Use for
    /// narrow-edge tests (shrink-to-fit, sidebar-collapse boundaries).
    static let minWindowSize = CGSize(width: 880, height: 540)

    // MARK: - Stored

    let window: NSWindow
    let container: NSView
    /// The mounted root VC. `MainSplitViewController` for `mainSplit`,
    /// the bare VC for `mount`.
    let rootViewController: NSViewController

    /// `rootViewController.view` — the top of the mounted tree, the usual
    /// ancestor coordinate space for `Geometry` assertions.
    var rootView: NSView { rootViewController.view }

    /// Cleanup hooks (temp dirs, UserDefaults suites) registered by the
    /// factory, run on `teardown()`.
    private var cleanups: [() -> Void] = []

    private init(
        window: NSWindow,
        container: NSView,
        rootViewController: NSViewController,
        cleanups: [() -> Void]
    ) {
        self.window = window
        self.container = container
        self.rootViewController = rootViewController
        self.cleanups = cleanups
    }

    // MARK: - Lifecycle

    /// Tear down the window and run every registered cleanup. Call from a
    /// test's `defer` or `addTeardownBlock`.
    func teardown() {
        window.contentView = nil
        window.close()
        for cleanup in cleanups.reversed() { cleanup() }
        cleanups.removeAll()
    }

    // MARK: - Generic mount

    /// Mount an arbitrary production `NSViewController` pinned to all four
    /// edges of an off-screen window. The lowest-level factory — use it
    /// for any VC the dedicated factories don't cover.
    static func mount(
        _ viewController: NSViewController,
        size: CGSize = defaultWindowSize,
        cleanups: [() -> Void] = []
    ) -> AppKitStage {
        let window = makeOffscreenWindow(size: size)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container

        viewController.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(viewController.view)
        NSLayoutConstraint.activate([
            viewController.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            viewController.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            viewController.view.topAnchor.constraint(equalTo: container.topAnchor),
            viewController.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.ccterm_orderFrontForTesting()
        container.layoutSubtreeIfNeeded()

        return AppKitStage(
            window: window, container: container,
            rootViewController: viewController, cleanups: cleanups)
    }

    private static func makeOffscreenWindow(size: CGSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(
                origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.alphaValue = 0.01
        return window
    }

    // MARK: - Runloop control

    /// Drain `DispatchQueue.main` + deferred AppKit layout for `seconds`,
    /// then flush autolayout once. The blunt instrument — prefer
    /// `drainUntil` when you know the condition you're waiting on.
    func drain(seconds: TimeInterval = 0.05) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        container.layoutSubtreeIfNeeded()
    }

    /// Settle async work — the observation hops, deferred attaches, and
    /// CATransaction commits that a structural change kicks off. Mirrors
    /// the `Task.sleep` + drain loop that AppKit tests hand-rolled, so a
    /// selection flip or session swap has landed before you assert.
    func settle(rounds: Int = 12, perRound: TimeInterval = 0.04) async {
        for _ in 0..<rounds {
            try? await Task.sleep(for: .seconds(perRound))
            drain(seconds: 0.01)
        }
        container.layoutSubtreeIfNeeded()
    }

    /// Pump the runloop until `condition` holds or `timeout` elapses.
    /// Returns whether the condition was met. Use over a fixed `settle`
    /// when there's an observable predicate — it's faster and self-documents
    /// what the test is waiting for.
    @discardableResult
    func drainUntil(
        timeout: TimeInterval = 2.0,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return condition()
    }

    /// Run `body` then flush autolayout **without** yielding the runloop —
    /// everything stays in one source phase. For invariants that must hold
    /// before any `@Observable` re-eval / beforeWaiting flush (e.g. "a
    /// source-phase write lands the geometry it depends on"). Returns
    /// `body`'s result so you can sample immediately.
    @discardableResult
    func sourcePhase<T>(_ body: () -> T) -> T {
        let result = body()
        container.layoutSubtreeIfNeeded()
        return result
    }

    // MARK: - Subview lookup

    /// First view of type `T` in the mounted tree (depth-first from
    /// `root`, defaulting to the stage root). Returns nil if absent.
    func find<T: NSView>(_ type: T.Type, in root: NSView? = nil) -> T? {
        Self.firstSubview(type, in: root ?? rootView)
    }

    /// Every view of type `T` in the mounted tree (depth-first).
    func findAll<T: NSView>(_ type: T.Type, in root: NSView? = nil) -> [T] {
        var out: [T] = []
        Self.collectSubviews(type, in: root ?? rootView, into: &out)
        return out
    }

    private static func firstSubview<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for sub in root.subviews {
            if let found = firstSubview(type, in: sub) { return found }
        }
        return nil
    }

    private static func collectSubviews<T: NSView>(
        _ type: T.Type, in root: NSView, into out: inout [T]
    ) {
        if let match = root as? T { out.append(match) }
        for sub in root.subviews { collectSubviews(type, in: sub, into: &out) }
    }
}
