import AppKit

/// Pure-math description of the dot-grid texture (`DotGridBackground.swift`
/// ported to AppKit, migration plan §4.6). Lifted out of the view so the
/// dot-center math is a CI-gateable assertion (`DotGridView` is otherwise a
/// "pure visual" leaf with no assertable surface — the geometry is the
/// computable logic per the test-realness rule).
///
/// Layout (verbatim from `DotGridBackground.swift:14-32`): dots on a square
/// `pitch` lattice, first center at `pitch / 2`, marching while `< size` on
/// each axis. Each dot is a `dotDiameter`-wide circle centered on the lattice
/// point (so the fill rect's origin is `center - radius`).
struct DotGridLayout {
    /// Lattice spacing (`DotGridBackground.pitch = 28`).
    var pitch: CGFloat = 28
    /// Circle diameter (`DotGridBackground.dotDiameter = 2.0`).
    var dotDiameter: CGFloat = 2.0
    /// `Color.primary` opacity (`DotGridBackground.opacity = 0.20`).
    var opacity: CGFloat = 0.20

    /// The fill rects for every dot whose center lands inside `size`. Mirrors
    /// `DotGridBackground.body`'s nested `while` exactly: `y` / `x` start at
    /// `pitch / 2` and advance by `pitch` while strictly `< size.{height,width}`.
    func dotRects(in size: CGSize) -> [CGRect] {
        guard pitch > 0, size.width > 0, size.height > 0 else { return [] }
        let radius = dotDiameter / 2
        var rects: [CGRect] = []
        var y = pitch / 2
        while y < size.height {
            var x = pitch / 2
            while x < size.width {
                rects.append(
                    CGRect(
                        x: x - radius, y: y - radius,
                        width: dotDiameter, height: dotDiameter))
                x += pitch
            }
            y += pitch
        }
        return rects
    }
}

/// Static, ultra-faint dot-grid texture drawn in pure AppKit — the backdrop
/// behind the New Session compose card (migration plan §4.6, replaces the
/// SwiftUI `DotGridBackground` `Canvas`). Decorative + hit-transparent.
///
/// Uses semantic `NSColor.labelColor` resolved per `draw(_:)` so it tracks the
/// system appearance automatically (no frozen `CALayer.cgColor`, R14) — the
/// `Color.primary` the SwiftUI version used maps to `labelColor`.
@MainActor
final class DotGridView: NSView {
    nonisolated deinit {}

    var layout: DotGridLayout {
        didSet { needsDisplay = true }
    }

    init(layout: DotGridLayout = DotGridLayout()) {
        self.layout = layout
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Decorative only — never absorb clicks (matches SwiftUI
    /// `.allowsHitTesting(false)`).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// No intrinsic size — the backdrop fills whatever its 4-edge pin gives it.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let color = NSColor.labelColor.withAlphaComponent(layout.opacity)
        ctx.setFillColor(color.cgColor)
        for rect in layout.dotRects(in: bounds.size) where rect.intersects(dirtyRect) {
            ctx.fillEllipse(in: rect)
        }
    }
}
