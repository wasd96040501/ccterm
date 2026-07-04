import AppKit

/// Detail-slot single-child container VC. **Dumb** by design: routing lives
/// in `DetailFlowCoordinator`; this VC only knows "swap this child for
/// that child, optionally crossfade the transition".
///
/// Splits the responsibility the old `DetailRouterViewController` carried
/// into two: containment (here) + routing (`DetailFlowCoordinator`). The
/// container has no notion of `ChildKind`, no `SessionManager` reference,
/// no `MainSelection` observation — every child that lands here arrives
/// pre-decided.
///
/// ## Crossfade
///
/// A same-source-phase swap can crossfade when there is an outgoing
/// child AND the view is on a live window. The incoming child is mounted
/// on **top** of the still-live outgoing one at `alpha == 0`, and the
/// outgoing child is parked in `fadingOutChild` for the animation
/// completion to tear down. Without a window, or when the caller asks
/// for `animated: false`, the swap is synchronous: outgoing torn down
/// (via `prepareForRemoval` + removeFromSuperview + removeFromParent)
/// before the caller returns.
///
/// A follow-up `setChild(_:_:)` in the middle of a running fade flushes
/// the parked child synchronously at the head — so rapid sidebar switches
/// collapse rather than stacking translucent ghosts.
@MainActor
final class DetailContainerViewController: NSViewController {
    /// The single mounted child. `private(set)` so tests / the coordinator
    /// can read it without widening the swap API.
    private(set) var currentChild: (NSViewController & DetailContainerChild)?

    /// The outgoing child mid-crossfade, kept mounted behind the incoming
    /// one until the fade completes. `nil` when no crossfade is in flight.
    /// A new `setChild(_:_:)` flushes it synchronously first.
    private var fadingOutChild: (NSViewController & DetailContainerChild)?

    /// Crossfade duration. Short — matches the snappy feel of a macOS
    /// source-list mode change; long enough to read as a transition rather
    /// than a flash. The fade is the only non-atomic part of the swap: the
    /// structural mount runs synchronously in the source phase, then the
    /// opacity animation rides CoreAnimation's clock from `beforeWaiting`.
    private static let childCrossfadeDuration: CFTimeInterval = 0.18

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        // Behind-window vibrancy backdrop for the whole detail half, shared
        // by every child. Each child mounts on top with a transparent view,
        // so the `.contentBackground` material shows through wherever they
        // don't paint. Matches the material the previous
        // `DetailRouterViewController` painted.
        let effect = NSVisualEffectView()
        effect.material = .contentBackground
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        view = effect
    }

    // MARK: - Swap API

    /// Mount `new` as the single child, tearing the outgoing one down.
    /// Pass `nil` to leave the container empty (post-teardown of the
    /// current child). Idempotent: passing the exact `new` instance that's
    /// already mounted is a no-op.
    ///
    /// `animated` gates the crossfade: `true` + outgoing child present +
    /// live window → build-in-front / fade-in-place / tear-outgoing-on-
    /// completion. Otherwise the swap is synchronous.
    func setChild(_ new: (NSViewController & DetailContainerChild)?, animated: Bool) {
        // Flush a still-running crossfade synchronously before staging a
        // new one — the late completion for the flushed child no-ops via
        // its `expected` guard. Same rationale as the parked-outgoing flush
        // in `TranscriptSwapCoordinator.attachSession`: a stacked
        // translucent ghost from A→B is undesirable when B→C lands.
        finishFadeOut()

        guard let new else {
            if let outgoing = currentChild {
                outgoing.prepareForRemoval()
                outgoing.view.removeFromSuperview()
                outgoing.removeFromParent()
            }
            currentChild = nil
            return
        }

        if new === currentChild { return }

        // Add the incoming child. Default `addSubview` z-order puts it on
        // top of the outgoing one — mirrors `TranscriptSwapCoordinator`'s
        // build-in-front ordering so a crossfade composites new-over-old.
        addChild(new)
        new.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(new.view)
        NSLayoutConstraint.activate([
            new.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            new.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            new.view.topAnchor.constraint(equalTo: view.topAnchor),
            new.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let outgoing = currentChild
        currentChild = new

        if animated, let outgoing, view.window != nil {
            new.view.wantsLayer = true
            outgoing.view.wantsLayer = true
            new.view.alphaValue = 0
            fadingOutChild = outgoing
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.childCrossfadeDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                new.view.animator().alphaValue = 1
                outgoing.view.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                self?.finishFadeOut(expected: outgoing)
            }
        } else if let outgoing {
            // Synchronous path (no window / not animated): tear the
            // outgoing child down before returning — deterministic, not
            // at the mercy of ARC timing.
            outgoing.prepareForRemoval()
            outgoing.view.removeFromSuperview()
            outgoing.removeFromParent()
        }
    }

    /// Tear down the parked outgoing child. Idempotent and called from
    /// two places: the crossfade completion (with `expected` set), and
    /// synchronously at the head of a new `setChild` to flush an in-flight
    /// fade (no `expected`). The `expected` guard makes a late completion
    /// for an already-flushed child a no-op.
    private func finishFadeOut(expected: NSViewController? = nil) {
        guard let outgoing = fadingOutChild else { return }
        if let expected, expected !== outgoing { return }
        fadingOutChild = nil
        outgoing.prepareForRemoval()
        outgoing.view.removeFromSuperview()
        outgoing.removeFromParent()
    }

    /// `nonisolated` so dealloc skips the `@MainActor` deinit executor-hop
    /// that aborts in the XCTest process under macOS 26 — matches every
    /// other `@MainActor` class in the codebase.
    nonisolated deinit {}
}
