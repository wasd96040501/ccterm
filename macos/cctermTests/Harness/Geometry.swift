import AppKit
import XCTest

@testable import ccterm

/// Geometry assertion vocabulary for AppKit verification tests. Turns
/// "is this component positioned right relative to its parent" into a
/// single readable call, with tolerance built in (AppKit geometry is
/// routinely sub-pixel) and a diagnostic that prints the actual regions
/// on failure.
///
/// Everything is expressed in a chosen **ancestor coordinate space** —
/// you pass the view and the ancestor you want to measure against, and
/// the helper does the `convert(_:to:)`. That is the unit these tests
/// care about: not absolute screen coordinates, but "where is the bar
/// inside the pane."
@MainActor
enum Geometry {

    /// Default geometry tolerance. One point covers normal sub-pixel /
    /// rounding drift; widen per call for animated or scaled content.
    static let tolerance: CGFloat = 1.0

    // MARK: - Region extraction

    /// `view`'s frame expressed in `ancestor`'s coordinate space. The
    /// fundamental query — "what region does this occupy inside that
    /// container." Both views must share a window.
    static func region(
        of view: NSView, in ancestor: NSView,
        file: StaticString = #filePath, line: UInt = #line
    ) -> CGRect {
        guard view.window != nil, view.window === ancestor.window else {
            XCTFail(
                "Geometry.region: \(describe(view)) and \(describe(ancestor)) "
                    + "are not in the same window (view.window=\(String(describing: view.window)))",
                file: file, line: line)
            return .zero
        }
        return view.convert(view.bounds, to: ancestor)
    }

    // MARK: - Containment / overlap

    /// `inner` lies entirely within `container`'s bounds (measured in
    /// `container`'s space), within `tolerance`. The "didn't overflow /
    /// clip out of its parent" check.
    static func assertContained(
        _ inner: NSView, in container: NSView,
        tolerance: CGFloat = tolerance,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let r = region(of: inner, in: container)
        let b = container.bounds
        let fits =
            r.minX >= b.minX - tolerance && r.maxX <= b.maxX + tolerance
            && r.minY >= b.minY - tolerance && r.maxY <= b.maxY + tolerance
        XCTAssertTrue(
            fits,
            "expected \(describe(inner)) contained in \(describe(container)): "
                + "inner=\(fmt(r)) container.bounds=\(fmt(b))",
            file: file, line: line)
    }

    /// `a` and `b` do not overlap (share no interior area), measured in
    /// `space`. Touching edges within `tolerance` is allowed.
    static func assertNoOverlap(
        _ a: NSView, _ b: NSView, in space: NSView,
        tolerance: CGFloat = tolerance,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let ra = region(of: a, in: space)
        let rb = region(of: b, in: space)
        let shrunk = ra.insetBy(dx: tolerance, dy: tolerance)
        let overlaps = shrunk.intersects(rb)
        XCTAssertFalse(
            overlaps,
            "expected no overlap between \(describe(a)) and \(describe(b)): "
                + "a=\(fmt(ra)) b=\(fmt(rb))",
            file: file, line: line)
    }

    // MARK: - Alignment / anchoring

    /// `view` is horizontally centered inside `container` within `tolerance`.
    static func assertCenteredX(
        _ view: NSView, in container: NSView,
        tolerance: CGFloat = tolerance,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let r = region(of: view, in: container)
        let viewMid = r.midX
        let containerMid = container.bounds.midX
        XCTAssertEqual(
            viewMid, containerMid, accuracy: tolerance,
            "expected \(describe(view)) centered-X in \(describe(container)): "
                + "view.midX=\(f(viewMid)) container.midX=\(f(containerMid)) frame=\(fmt(r))",
            file: file, line: line)
    }

    /// `view` is pinned to `container`'s bottom edge with `inset` points of
    /// gap, within `tolerance`. Works in either flipped-ness — the gap is
    /// measured from whichever container edge is visually the bottom.
    static func assertBottomAnchored(
        _ view: NSView, in container: NSView, inset: CGFloat,
        tolerance: CGFloat = tolerance,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let r = region(of: view, in: container)
        // In a flipped container the visual bottom is `bounds.maxY`; in a
        // non-flipped one it's `bounds.minY`. Measure the gap accordingly.
        let gap =
            container.isFlipped
            ? container.bounds.maxY - r.maxY
            : r.minY - container.bounds.minY
        XCTAssertEqual(
            gap, inset, accuracy: tolerance,
            "expected \(describe(view)) bottom-anchored with inset \(f(inset)) "
                + "in \(describe(container)) (flipped=\(container.isFlipped)): "
                + "gap=\(f(gap)) frame=\(fmt(r)) container.bounds=\(fmt(container.bounds))",
            file: file, line: line)
    }

    /// Edge to align two regions on, for `assertAligned`.
    enum Edge { case leading, trailing, top, bottom, centerX, centerY }

    /// `a` and `b` agree on `edge` within `tolerance`, measured in `space`.
    static func assertAligned(
        _ a: NSView, _ b: NSView, on edge: Edge, in space: NSView,
        tolerance: CGFloat = tolerance,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let ra = region(of: a, in: space)
        let rb = region(of: b, in: space)
        let (va, vb): (CGFloat, CGFloat)
        switch edge {
        case .leading: (va, vb) = (ra.minX, rb.minX)
        case .trailing: (va, vb) = (ra.maxX, rb.maxX)
        case .top: (va, vb) = (ra.minY, rb.minY)
        case .bottom: (va, vb) = (ra.maxY, rb.maxY)
        case .centerX: (va, vb) = (ra.midX, rb.midX)
        case .centerY: (va, vb) = (ra.midY, rb.midY)
        }
        XCTAssertEqual(
            va, vb, accuracy: tolerance,
            "expected \(describe(a)) and \(describe(b)) aligned on \(edge): "
                + "a=\(f(va)) b=\(f(vb)) (a.frame=\(fmt(ra)) b.frame=\(fmt(rb)))",
            file: file, line: line)
    }

    // MARK: - Size

    /// `view`'s width is at most `cap` within `tolerance`. The width-cap
    /// check (e.g. a centered bar that should never exceed `maxLayoutWidth`).
    static func assertWidth(
        _ view: NSView, atMost cap: CGFloat,
        tolerance: CGFloat = tolerance,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let w = view.bounds.width
        XCTAssertLessThanOrEqual(
            w, cap + tolerance,
            "expected \(describe(view)) width ≤ \(f(cap)): got \(f(w))",
            file: file, line: line)
    }

    /// `view`'s size matches `expected` within `tolerance` on both axes.
    static func assertSize(
        _ view: NSView, equals expected: CGSize,
        tolerance: CGFloat = tolerance,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            view.bounds.width, expected.width, accuracy: tolerance,
            "width mismatch for \(describe(view)): got \(f(view.bounds.width)) "
                + "expected \(f(expected.width))",
            file: file, line: line)
        XCTAssertEqual(
            view.bounds.height, expected.height, accuracy: tolerance,
            "height mismatch for \(describe(view)): got \(f(view.bounds.height)) "
                + "expected \(f(expected.height))",
            file: file, line: line)
    }

    // MARK: - Viewport / scroll

    /// `view`'s region is at least partly visible inside `scrollView`'s
    /// clip (the document is scrolled such that the view is on-screen).
    static func assertWithinViewport(
        _ view: NSView, of scrollView: NSScrollView,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let clip = scrollView.contentView
        let r = region(of: view, in: clip)
        let visible = clip.bounds
        XCTAssertTrue(
            visible.intersects(r),
            "expected \(describe(view)) visible in scroll viewport: "
                + "view=\(fmt(r)) clip.bounds=\(fmt(visible))",
            file: file, line: line)
    }

    // MARK: - Formatting

    private static func f(_ v: CGFloat) -> String { String(format: "%.1f", v) }
    private static func fmt(_ r: CGRect) -> String {
        "(\(f(r.minX)), \(f(r.minY)), \(f(r.width))×\(f(r.height)))"
    }
    private static func fmt(_ s: CGSize) -> String { "\(f(s.width))×\(f(s.height))" }
    private static func describe(_ view: NSView) -> String { String(describing: type(of: view)) }
}
