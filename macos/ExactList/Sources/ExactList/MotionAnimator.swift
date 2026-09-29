import AppKit
import ExactListCore

/// Turns a `CommitPlan` into CoreAnimation, and nothing else (SPEC §8).
///
/// For each motion that isn't still, it adds additive `position.y` and
/// `bounds.size.height` animations from `start − end` to 0 on the row's
/// container, plus the transition's opacity or content offset (M9). All of
/// them share one duration and one timing function. It never removes an
/// animation it didn't finish: a later commit adds on top (M8). It never reads
/// a presentation layer.
///
/// Every animation goes on the container's layer, never on the host view's
/// (P5). A slide (M9) offsets the content with an additive animation of the
/// container layer's `sublayerTransform.translation.y` (or `.x`), not by
/// moving the hosted view.
@MainActor
final class MotionAnimator {

    /// Weak: the list owns this.
    weak var owner: MotionAnimatorOwner?

    /// One commit's animations, until they end.
    private final class Flight {
        let id: Int
        let containers: [RowContainerView]
        let retiring: [RowContainerView]
        let completion: (Bool) -> Void
        var isCancelled = false

        init(
            id: Int, containers: [RowContainerView], retiring: [RowContainerView], completion: @escaping (Bool) -> Void
        ) {
            self.id = id
            self.containers = containers
            self.retiring = retiring
            self.completion = completion
        }
    }

    private var flights: [Flight] = []
    private var nextID = 0

    init() {}

    /// Adds the plan's animations to `containers`, keyed by new row, and to
    /// `retiring`, keyed by old row: the removed rows' containers, which the
    /// plan's `.removed` motions name by their old index. Nothing animates when
    /// `duration` is 0; the completion still runs on a later turn (U8). The
    /// retiring containers are handed back once this commit's animations end.
    func animate(
        _ plan: CommitPlan, containers: [Int: RowContainerView], retiring: [Int: RowContainerView],
        duration: TimeInterval, timing: CAMediaTimingFunction, completion: @escaping (Bool) -> Void
    ) {
        let moving = plan.motions.filter { !$0.isStill }
        guard duration > 0, !moving.isEmpty else {
            owner?.motionAnimator(self, didFinishCommitRetiring: Array(retiring.values))
            DispatchQueue.main.async { completion(true) }
            return
        }

        let id = nextID
        nextID += 1
        let removedMotions = Set(moving.filter { $0.kind == .removed }.map(\.row))
        var animated: [RowContainerView] = []

        CATransaction.begin()
        for motion in moving {
            let container = motion.kind == .removed ? retiring[motion.row] : containers[motion.row]
            guard let container, let layer = container.layer else { continue }
            if motion.kind == .removed {
                // A removed row's model is where it ends: its slot closed, zero
                // tall. The host view keeps its own height inside (M2).
                container.frame = NSRect(
                    x: 0, y: motion.endTop + plan.offset, width: container.frame.width, height: motion.endHeight)
                container.superview?.addSubview(container, positioned: .below, relativeTo: nil)
            } else if motion.kind == .moved {
                container.superview?.addSubview(container, positioned: .above, relativeTo: nil)
            }
            add(additive: "position.y", from: motion.startTop - motion.endTop, on: layer, id, duration, timing)
            add(
                additive: "bounds.size.height", from: motion.startHeight - motion.endHeight, on: layer, id, duration,
                timing)
            addTransition(motion, on: layer, id, duration, timing)
            animated.append(container)
        }
        let flight = Flight(
            id: id, containers: animated, retiring: retiring.filter { removedMotions.contains($0.key) }.map(\.value),
            completion: completion)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.land(flight) }
        }
        CATransaction.commit()
        flights.append(flight)

        let handedBack = retiring.filter { !removedMotions.contains($0.key) }.map(\.value)
        if !handedBack.isEmpty { owner?.motionAnimator(self, didFinishCommitRetiring: handedBack) }
    }

    /// The rows whose containers are still in flight, in the current numbering:
    /// what `RowPlacement.place(rows:keeping:…)` keeps mounted (P1).
    var rowsInFlight: IndexSet {
        var rows = IndexSet()
        for flight in flights where !flight.isCancelled {
            for container in flight.containers where container.row >= 0 {
                rows.insert(container.row)
            }
        }
        return rows
    }

    /// Renumbers the rows in flight through a batch. Containers carry their own
    /// row, which `RowPlacement.apply(_:)` renumbers, so there is nothing of
    /// the animator's own to change.
    func apply(_ map: RowIndexMap) {}

    /// U7: removes every animation. Outstanding completions get `false`.
    func cancelAll() {
        let cancelled = flights
        flights.removeAll()
        for flight in cancelled {
            flight.isCancelled = true
            for container in flight.containers { container.layer?.removeAllAnimations() }
            flight.completion(false)
        }
    }

    private func land(_ flight: Flight) {
        guard let index = flights.firstIndex(where: { $0.id == flight.id }) else { return }
        let landed = flights.remove(at: index)
        owner?.motionAnimator(self, didFinishCommitRetiring: landed.retiring)
        landed.completion(true)
    }

    private func add(
        additive keyPath: String, from delta: CGFloat, on layer: CALayer, _ id: Int, _ duration: TimeInterval,
        _ timing: CAMediaTimingFunction
    ) {
        guard delta != 0 else { return }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.isAdditive = true
        animation.fromValue = delta
        animation.toValue = 0
        animation.duration = duration
        animation.timingFunction = timing
        layer.add(animation, forKey: "exactlist.\(id).\(keyPath)")
    }

    /// M9: fades and slides for inserted and removed rows.
    private func addTransition(
        _ motion: RowMotion, on layer: CALayer, _ id: Int, _ duration: TimeInterval, _ timing: CAMediaTimingFunction
    ) {
        guard motion.kind == .inserted || motion.kind == .removed else { return }
        let entering = motion.kind == .inserted
        if motion.transition.contains(.effectFade) {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = entering ? 0 : 1
            fade.toValue = entering ? 1 : 0
            fade.duration = duration
            fade.timingFunction = timing
            if !entering { layer.opacity = 0 }
            layer.add(fade, forKey: "exactlist.\(id).opacity")
        }
        guard let slide = motion.transition.slide else { return }
        let height = max(motion.startHeight, motion.endHeight)
        let width = layer.bounds.width
        let (keyPath, distance): (String, CGFloat) =
            switch slide {
            case .slideUp: ("sublayerTransform.translation.y", height)
            case .slideDown: ("sublayerTransform.translation.y", -height)
            case .slideLeft: ("sublayerTransform.translation.x", width)
            default: ("sublayerTransform.translation.x", -width)
            }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.isAdditive = true
        animation.fromValue = entering ? distance : 0
        animation.toValue = entering ? 0 : -distance
        animation.duration = duration
        animation.timingFunction = timing
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = entering
        layer.add(animation, forKey: "exactlist.\(id).slide")
    }
}
