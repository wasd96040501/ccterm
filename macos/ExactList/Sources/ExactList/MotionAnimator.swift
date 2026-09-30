import AppKit
import ExactListCore

/// Runs motion on AppKit's animation engine, on the real frames (SPEC §8, S3).
///
/// Each commit's motion, and each animated scroll, gets its own
/// `MotionClock`, which `animator()` drives from 0 to 1 with the commit's
/// duration and timing function. On every value AppKit sets, the rows in that
/// motion get their frames, opacity and content offset (M2, M9), or the clip
/// view its offset (S3). No CoreAnimation animation is added anywhere, so what
/// is presented is the model, and AppKit draws and hit-tests every row where
/// it is on screen (M3).
///
/// A row in several motions is at its final frame plus the remaining part of
/// each (M8), so a later commit stops nothing. A container in flight is
/// placed only here, until its motion ends; `RowPlacement` leaves it alone.
@MainActor
final class MotionAnimator {

    /// Weak: the list owns this.
    weak var delegate: MotionAnimatorDelegate?

    /// `clockHost` holds the clocks, which are hidden and have no size.
    init(clockHost: NSView) {
        self.clockHost = clockHost
    }

    /// The geometry the rows in flight are going to: the committed heights at
    /// `width`. Every row in flight is set again against them, so a commit that
    /// changes them, or the width, carries the rows still moving along.
    func update(heights: RowHeights, width: CGFloat) {
        self.heights = heights
        self.width = width
        present(Set(flights.flatMap { $0.parts.keys }))
    }

    /// Starts the plan's motion: `containers` keyed by new row, and
    /// `retiring`, the removed rows that move out, by old row, which is how the
    /// plan's `.removed` motions name them. Every moving row is at its start
    /// (`p = 0`) when this returns, and the retiring containers are handed
    /// back once the motion ends. When nothing moves, the completion still
    /// runs on a later turn (U8).
    func animate(
        _ plan: CommitPlan, containers: [Int: ListRowView], retiring: [Int: ListRowView],
        duration: TimeInterval, timing: CAMediaTimingFunction, completion: @escaping (Bool) -> Void
    ) {
        let moving = plan.motions.filter { !$0.isStill }
        guard duration > 0, !moving.isEmpty else {
            DispatchQueue.main.async { completion(true) }
            return
        }

        let flight = Flight(clock: MotionClock(), retiring: Array(retiring.values), completion: completion)
        NSAnimationContext.withoutAnimation {
            for motion in moving {
                add(motion, of: plan, containers: containers, retiring: retiring, to: flight)
            }
        }
        flights.append(flight)
        run(flight.clock, duration: duration, timing: timing) { [weak self, weak flight] progress in
            guard let self, let flight, !flight.isCancelled else { return }
            flight.progress = progress
            self.present(Set(flight.parts.keys))
        } completion: { [weak self] in
            self?.land(flight)
        }
    }

    /// The rows whose containers are still in flight, in the current numbering:
    /// what `RowPlacement.place(rows:keeping:…)` keeps mounted and leaves to
    /// this (P1).
    var rowsInFlight: IndexSet {
        var rows = IndexSet()
        for flight in flights {
            for part in flight.parts.values where part.container.row >= 0 {
                rows.insert(part.container.row)
            }
        }
        return rows
    }

    // MARK: - Animated scrolls (S3)

    /// Moves the offset from `offset` to `destination` on a clock of its own,
    /// replacing any scroll in flight.
    func scroll(from offset: CGFloat, to destination: CGFloat, duration: TimeInterval, timing: CAMediaTimingFunction) {
        cancelScroll()
        let scroll = ScrollFlight(clock: MotionClock(), start: offset, destination: destination)
        self.scroll = scroll
        run(scroll.clock, duration: duration, timing: timing) { [weak self, weak scroll] progress in
            guard let self, let scroll, self.scroll === scroll else { return }
            self.delegate?.motionAnimator(
                self, scrollTo: scroll.destination + (scroll.start - scroll.destination) * (1 - progress))
        } completion: { [weak self, weak scroll] in
            guard let self, let scroll, self.scroll === scroll else { return }
            self.end(scroll)
        }
    }

    /// A commit moved the offset by `delta` during a scroll: the destination,
    /// and the start, move with it, so the flight carries on from there.
    func shiftScroll(by delta: CGFloat) {
        guard let scroll, delta != 0 else { return }
        scroll.start += delta
        scroll.destination += delta
    }

    /// Ends the scroll in flight where it is: the reader scrolled, or U7.
    func cancelScroll() {
        guard let scroll else { return }
        end(scroll)
    }

    // MARK: - Cancelling (U7)

    /// U7: every motion and scroll stops, and returns the containers that were
    /// animating out. Outstanding completions get `false`, on a later turn
    /// like every completion (U8).
    func cancelAll() -> [ListRowView] {
        cancelScroll()
        let cancelled = flights
        flights.removeAll()
        var retiring: [ListRowView] = []
        for flight in cancelled {
            flight.isCancelled = true
            stop(flight.clock)
            for part in flight.parts.values {
                part.container.alphaValue = 1
                part.container.contentOffset = .zero
            }
            retiring += flight.retiring
            DispatchQueue.main.async { flight.completion(false) }
        }
        return retiring
    }

    // MARK: - Private

    /// One row's part in one commit's motion: how far its start is from its
    /// end, and its effect (M2, M9).
    private struct Part {
        let container: ListRowView
        /// `start − end`, of the screen top and of the height.
        var top: CGFloat
        var height: CGFloat
        var transition: RowTransition
        var entering: Bool
        /// The slide's distance, signed: how far the content starts from, or
        /// ends at, when it enters or leaves.
        var slide: CGFloat
        /// A removed row's final frame; any other row's is its row's.
        var end: NSRect?
    }

    /// One commit's motion, until it ends.
    private final class Flight {
        let clock: MotionClock
        var parts: [ObjectIdentifier: Part] = [:]
        var progress: CGFloat = 0
        let retiring: [ListRowView]
        let completion: (Bool) -> Void
        var isCancelled = false

        init(clock: MotionClock, retiring: [ListRowView], completion: @escaping (Bool) -> Void) {
            self.clock = clock
            self.retiring = retiring
            self.completion = completion
        }
    }

    /// One animated scroll, until it ends.
    private final class ScrollFlight {
        let clock: MotionClock
        var start: CGFloat
        var destination: CGFloat

        init(clock: MotionClock, start: CGFloat, destination: CGFloat) {
            self.clock = clock
            self.start = start
            self.destination = destination
        }
    }

    private let clockHost: NSView
    private var flights: [Flight] = []
    private var scroll: ScrollFlight?
    private var heights = RowHeights()
    private var width: CGFloat = 0

    /// Adds `motion`'s part to `flight`, and puts a moved row above the
    /// others and a removed one below them (M10).
    private func add(
        _ motion: RowMotion, of plan: CommitPlan, containers: [Int: ListRowView],
        retiring: [Int: ListRowView], to flight: Flight
    ) {
        let container = motion.kind == .removed ? retiring[motion.row] : containers[motion.row]
        guard let container else { return }
        var part = Part(
            container: container, top: motion.startTop - motion.endTop,
            height: motion.startHeight - motion.endHeight, transition: [], entering: true, slide: 0, end: nil)
        if motion.kind == .inserted || motion.kind == .removed {
            part.transition = motion.transition
            part.entering = motion.kind == .inserted
            part.slide =
                switch motion.transition.slide {
                case .slideUp?: max(motion.startHeight, motion.endHeight)
                case .slideDown?: -max(motion.startHeight, motion.endHeight)
                case .slideLeft?: width
                case .slideRight?: -width
                default: 0
                }
        }
        if motion.kind == .removed {
            // A removed row has no row left to take a frame from: it ends
            // in its gap, zero tall (M2).
            part.end = NSRect(x: 0, y: motion.endTop + plan.offset, width: width, height: motion.endHeight)
            container.superview?.addSubview(container, positioned: .below, relativeTo: nil)
        } else if motion.kind == .moved {
            container.superview?.addSubview(container, positioned: .above, relativeTo: nil)
        }
        flight.parts[ObjectIdentifier(container)] = part
    }

    /// Starts `clock` at 0, which `tick` hears before this returns, then
    /// animates it to 1 in a group of its own, nested in the caller's (M3).
    private func run(
        _ clock: MotionClock, duration: TimeInterval, timing: CAMediaTimingFunction,
        tick: @escaping (CGFloat) -> Void, completion: @escaping () -> Void
    ) {
        clockHost.addSubview(clock)
        // Frames written on a tick are the motion itself: nothing of AppKit's
        // or CoreAnimation's own may animate them again. The first tick runs
        // inside the caller's group.
        clock.onTick = { progress in NSAnimationContext.withoutAnimation { tick(progress) } }
        NSAnimationContext.withoutAnimation { clock.progress = 0 }
        // Not inside an explicit CATransaction, or the caller's group would
        // not wait for this one (measured).
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = timing
            clock.animator().progress = 1
        } completionHandler: {
            MainActor.assumeIsolated { completion() }
        }
    }

    /// Stops `clock` where it is: a duration-0 group takes over its property,
    /// which ends the running animation and runs its completion (measured).
    private func stop(_ clock: MotionClock) {
        clock.onTick = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            clock.animator().progress = 1
        }
        clock.removeFromSuperview()
    }

    private func end(_ scroll: ScrollFlight) {
        self.scroll = nil
        stop(scroll.clock)
    }

    /// Sets each container in `ids` to its final frame plus the remaining part
    /// of every motion it is in, with its opacity and content offset (M2, M8,
    /// M9).
    private func present(_ ids: Set<ObjectIdentifier>) {
        for id in ids {
            var container: ListRowView?
            var end: NSRect?
            var top: CGFloat = 0
            var height: CGFloat = 0
            var opacity: CGFloat = 1
            var offset: CGFloat = 0
            var sideways = false
            for flight in flights {
                guard let part = flight.parts[id] else { continue }
                let remaining = 1 - flight.progress
                container = part.container
                end = part.end ?? end
                top += part.top * remaining
                height += part.height * remaining
                if part.transition.contains(.effectFade) {
                    opacity *= part.entering ? flight.progress : remaining
                }
                if part.slide != 0 {
                    offset += part.entering ? part.slide * remaining : -part.slide * flight.progress
                    sideways = part.transition.slide == .slideLeft || part.transition.slide == .slideRight
                }
            }
            guard let container else { continue }
            let row = container.row
            let final: NSRect
            if let end {
                final = end
            } else if row >= 0, row < heights.count {
                final = NSRect(x: 0, y: heights.top(ofRow: row), width: width, height: heights[row])
            } else {
                continue
            }
            let frame = NSRect(
                x: 0, y: final.minY + top, width: width, height: max(0, final.height + height))
            if container.frame != frame { container.frame = frame }
            if container.alphaValue != opacity { container.alphaValue = opacity }
            container.contentOffset = sideways ? CGPoint(x: offset, y: 0) : CGPoint(x: 0, y: offset)
        }
    }

    /// A commit's motion has ended: its rows go to where the other motions
    /// they are in put them, and its retiring containers are handed back.
    private func land(_ flight: Flight) {
        guard !flight.isCancelled, let index = flights.firstIndex(where: { $0 === flight }) else { return }
        flights.remove(at: index)
        flight.clock.onTick = nil
        flight.clock.removeFromSuperview()
        NSAnimationContext.withoutAnimation {
            present(Set(flight.parts.keys))
            for part in flight.parts.values
            where !flights.contains(where: { $0.parts[ObjectIdentifier(part.container)] != nil }) {
                // In no motion now: exactly at its row's frame, whatever the
                // last tick delivered.
                let row = part.container.row
                if row >= 0, row < heights.count {
                    let frame = NSRect(x: 0, y: heights.top(ofRow: row), width: width, height: heights[row])
                    if part.container.frame != frame { part.container.frame = frame }
                }
                part.container.alphaValue = 1
                part.container.contentOffset = .zero
            }
            delegate?.motionAnimator(self, didFinishCommitRetiring: flight.retiring)
        }
        flight.completion(true)
    }
}
