import AppKit
import XCTest

@testable import ccterm

/// CI-gate (non-snapshot) tests for `TodoStatusGlyphView` — the AppKit
/// replacement for the SwiftUI `TodoStatusGlyph`. These run on the unfiltered
/// `make test-unit` suite and drive the **real** public surface
/// (`setState(_:muted:)`), asserting on the produced `CAShapeLayer`'s
/// observable properties:
///
/// - the completed glyph's `fillRule == .evenOdd` (plan §8 R18 — the default
///   `.nonZero` would render a solid disc),
/// - the rotation animation present **iff** `inProgress && !muted` (R17 —
///   add/remove on every `setState`, recycle-in-place),
/// - the dotted dash + round cap present under the same predicate (proving
///   muted `inProgress` renders identical to `pending`),
/// - per-state stroke vs fill geometry, one reused shape-layer instance,
/// - footprint invariance across all four `(status, muted)` combos,
/// - the appearance-flip cgColor re-resolve (R14 — `CALayer.cgColor` freeze),
/// - the three-ellipse completed path + the `dotScale` inner-dot diameter.
@MainActor
final class TodoStatusGlyphViewTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - R18: completed even-odd fill rule

    func testCompletedGlyphUsesEvenOddFillRule() {
        let glyph = TodoStatusGlyphView()
        glyph.setState(.completed, muted: false)
        XCTAssertEqual(
            glyph.resolvedFillRule, .evenOdd,
            "completed glyph must set fillRule = .evenOdd (default .nonZero → solid disc)")

        // Independent of muted (the completed glyph is grey either way).
        glyph.setState(.completed, muted: true)
        XCTAssertEqual(glyph.resolvedFillRule, .evenOdd)
    }

    func testCompletedGlyphReassertsEvenOddAfterRelayout() {
        // The fillRule must be reapplied on every completed-path rebuild in
        // layout() (R18). Resize → relayout → still even-odd.
        let glyph = TodoStatusGlyphView()
        glyph.setState(.completed, muted: false)
        glyph.frame = NSRect(x: 0, y: 0, width: 14, height: 14)
        glyph.layoutSubtreeIfNeeded()
        XCTAssertEqual(glyph.resolvedFillRule, .evenOdd)

        glyph.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        glyph.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            glyph.resolvedFillRule, .evenOdd,
            "fillRule must survive a relayout / path rebuild")
    }

    func testCompletedGlyphIsFillOnly() {
        let glyph = TodoStatusGlyphView()
        glyph.setState(.completed, muted: false)
        XCTAssertNotNil(glyph.resolvedFillColor, "completed glyph fills")
        XCTAssertNil(glyph.resolvedStrokeColor, "completed glyph has no stroke")
        XCTAssertEqual(glyph.resolvedLineWidth, 0, accuracy: 0.0001)
        XCTAssertNotNil(glyph.resolvedPath)
        XCTAssertFalse(glyph.resolvedPath!.isEmpty)
    }

    // MARK: - Completed path identity (3 ellipses + dot diameter)

    func testCompletedPathHasThreeSubpaths() {
        let glyph = TodoStatusGlyphView()
        glyph.frame = NSRect(x: 0, y: 0, width: 14, height: 14)
        glyph.setState(.completed, muted: false)
        glyph.layoutSubtreeIfNeeded()
        // Three addEllipse calls → three moveTo sub-path starts.
        XCTAssertEqual(
            glyph.resolvedSubpathCount, 3,
            "completed path = outer disc + ring inner edge + inner dot")
    }

    func testCompletedInnerDotDiameterMatchesDotScale() {
        // Measure the THIRD ellipse (the inner dot) of the PRODUCTION path and
        // assert its diameter == min(w,h) * dotScale (= 14 * 0.62 = 8.68). This
        // walks the real CGPath sub-paths rather than re-deriving the constant,
        // so it fails if the production geometry regresses (a tautology that
        // re-computes `min(w,h) * dotScale` on both sides could not).
        let rect = CGRect(x: 0, y: 0, width: 14, height: 14)
        let path = TodoStatusGlyphView.completedPath(in: rect)

        // The three addEllipse calls run largest → smallest, so the inner dot
        // is the last sub-path. Split the path at each moveTo and take the
        // bounding box of the final segment.
        let subpathBoxes = boundingBoxesPerSubpath(of: path)
        XCTAssertEqual(subpathBoxes.count, 3, "completed path = outer disc + ring inner edge + inner dot")
        let dotBox = try? XCTUnwrap(subpathBoxes.last)
        if let dotBox {
            XCTAssertEqual(dotBox.width, 14 * 0.62, accuracy: 0.01, "inner-dot diameter = min(w,h) * dotScale")
            XCTAssertEqual(dotBox.height, 14 * 0.62, accuracy: 0.01)
            // Concentric with the 14×14 box.
            XCTAssertEqual(dotBox.midX, rect.midX, accuracy: 0.01)
            XCTAssertEqual(dotBox.midY, rect.midY, accuracy: 0.01)
        }

        // The full path's bounding box equals the outer disc (the first,
        // largest ellipse), proving the dot is concentric & inside.
        XCTAssertEqual(path.boundingBox.width, 14, accuracy: 0.5)
        XCTAssertEqual(path.boundingBox.height, 14, accuracy: 0.5)
    }

    /// Split a `CGPath` into one bounding box per sub-path (each `moveTo`
    /// starts a new sub-path). Used to measure the completed glyph's inner
    /// dot against the production geometry rather than a re-derived constant.
    private func boundingBoxesPerSubpath(of path: CGPath) -> [CGRect] {
        var boxes: [CGRect] = []
        var current = CGRect.null
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                if !current.isNull { boxes.append(current) }
                current = CGRect(origin: e.points[0], size: .zero)
            case .addLineToPoint:
                current = current.union(CGRect(origin: e.points[0], size: .zero))
            case .addQuadCurveToPoint:
                current = current.union(CGRect(origin: e.points[0], size: .zero))
                current = current.union(CGRect(origin: e.points[1], size: .zero))
            case .addCurveToPoint:
                current = current.union(CGRect(origin: e.points[0], size: .zero))
                current = current.union(CGRect(origin: e.points[1], size: .zero))
                current = current.union(CGRect(origin: e.points[2], size: .zero))
            case .closeSubpath:
                break
            @unknown default:
                break
            }
        }
        if !current.isNull { boxes.append(current) }
        return boxes
    }

    // MARK: - R17: rotation present IFF inProgress && !muted

    func testRotationPresentForLiveInProgressOnly() throws {
        let glyph = TodoStatusGlyphView()

        glyph.setState(.inProgress, muted: false)
        let anim = try? XCTUnwrap(glyph.resolvedRotationAnimation)
        XCTAssertNotNil(anim, "live inProgress must spin")
        if let anim {
            XCTAssertEqual(anim.keyPath, "transform.rotation.z")
            XCTAssertEqual(anim.duration, TodoStatusGlyphView.rotationDuration, accuracy: 0.0001)
            XCTAssertEqual(anim.duration, 6.0, accuracy: 0.0001)
            XCTAssertEqual(anim.repeatCount, .infinity)
            XCTAssertEqual(anim.fromValue as? Double, 0)
            XCTAssertEqual(try XCTUnwrap(anim.toValue as? Double), 2 * Double.pi, accuracy: 0.0001)
            XCTAssertFalse(anim.isRemovedOnCompletion)
            XCTAssertEqual(anim.timingFunction, CAMediaTimingFunction(name: .linear))
        }

        // muted inProgress: no spin.
        glyph.setState(.inProgress, muted: true)
        XCTAssertNil(glyph.resolvedRotationAnimation, "muted inProgress must not spin")

        // completed / pending: no spin.
        glyph.setState(.completed, muted: false)
        XCTAssertNil(glyph.resolvedRotationAnimation)
        glyph.setState(.pending, muted: false)
        XCTAssertNil(glyph.resolvedRotationAnimation)

        // Recycle-in-place: re-added on returning to the predicate.
        glyph.setState(.inProgress, muted: false)
        XCTAssertNotNil(
            glyph.resolvedRotationAnimation,
            "rotation must be re-added on return to live inProgress (recycle-in-place)")
    }

    func testRotationSeededFromLiveInProgressInit() {
        // A glyph constructed directly at live inProgress installs the spin in
        // init (the predicate-keyed lifecycle, not viewDidMoveToWindow).
        let glyph = TodoStatusGlyphView(status: .inProgress, muted: false)
        XCTAssertNotNil(glyph.resolvedRotationAnimation)
    }

    func testRotationReAssertedOnWindowReattach() {
        // Core Animation strips a layer's animations when it leaves the window
        // tree; the live spinner's production host (NSPopover) tears down + re-
        // builds its content on every show/close, and setState's idempotence
        // guard can't restart the spin on an unchanged (status, muted). So the
        // glyph re-arms the rotation in viewDidMoveToWindow (the onAppear
        // equivalent). Drive the real attach/detach lifecycle and assert.
        let glyph = TodoStatusGlyphView(status: .inProgress, muted: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
            styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host

        // Attach: rotation present.
        host.addSubview(glyph)
        XCTAssertNotNil(
            glyph.resolvedRotationAnimation,
            "live inProgress glyph must spin once attached to a window")

        // Detach: rotation removed (so a closed/recycled host carries no stale
        // animation).
        glyph.removeFromSuperview()
        XCTAssertNil(
            glyph.resolvedRotationAnimation,
            "rotation must be cleared on window detach")

        // Reattach: rotation re-armed (the popover-reopen case).
        host.addSubview(glyph)
        XCTAssertNotNil(
            glyph.resolvedRotationAnimation,
            "rotation must be re-asserted on window reattach (popover reopen parity)")
    }

    func testNonLiveGlyphDoesNotSpinOnWindowAttach() {
        // A muted-inProgress (or pending/completed) glyph must never install
        // the rotation on attach — the live-spinner predicate gates it.
        let glyph = TodoStatusGlyphView(status: .inProgress, muted: true)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
            styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host

        host.addSubview(glyph)
        XCTAssertNil(
            glyph.resolvedRotationAnimation,
            "muted inProgress glyph must not spin even when attached")
    }

    // MARK: - Dash + cap present IFF live inProgress (muted == pending)

    func testDashPatternPresentForLiveInProgressOnly() {
        let glyph = TodoStatusGlyphView()

        glyph.setState(.inProgress, muted: false)
        let dash = glyph.resolvedLineDashPattern
        XCTAssertEqual(dash?.count, 2)
        XCTAssertEqual(dash?[0].doubleValue ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(
            dash?[1].doubleValue ?? -1,
            Double(TodoStatusGlyphView.strokeWidth * TodoStatusGlyphView.dashGapMultiplier),
            accuracy: 0.0001)
        XCTAssertEqual(dash?[1].doubleValue ?? -1, 3.08, accuracy: 0.0001)
        XCTAssertEqual(glyph.resolvedLineCap, .round, "dotted ring needs a round cap")

        // muted inProgress == pending: plain ring, no dash.
        glyph.setState(.inProgress, muted: true)
        XCTAssertNil(glyph.resolvedLineDashPattern, "muted inProgress is a plain ring")

        glyph.setState(.pending, muted: false)
        XCTAssertNil(glyph.resolvedLineDashPattern)

        glyph.setState(.completed, muted: false)
        XCTAssertNil(glyph.resolvedLineDashPattern)
    }

    func testMutedInProgressMatchesPendingStrokeGeometry() {
        // Both are plain inset rings: lineWidth 1.4, fillColor clear, no dash.
        let glyph = TodoStatusGlyphView()
        glyph.frame = NSRect(x: 0, y: 0, width: 14, height: 14)

        glyph.setState(.pending, muted: false)
        glyph.layoutSubtreeIfNeeded()
        let pendingWidth = glyph.resolvedLineWidth
        let pendingDash = glyph.resolvedLineDashPattern
        let pendingFill = glyph.resolvedFillColor
        let pendingPathBox = glyph.resolvedPath?.boundingBox

        glyph.setState(.inProgress, muted: true)
        glyph.layoutSubtreeIfNeeded()
        XCTAssertEqual(glyph.resolvedLineWidth, pendingWidth, accuracy: 0.0001)
        // Both the pending ring and the muted-inProgress ring are plain: assert
        // BOTH are explicitly nil (a `?? 0`-masked count comparison would pass
        // 0 == 0 regardless, so it couldn't catch a dash leaking onto either).
        XCTAssertNil(pendingDash, "pending ring has no dash")
        XCTAssertNil(glyph.resolvedLineDashPattern, "muted inProgress ring has no dash")
        XCTAssertEqual(glyph.resolvedFillColor, pendingFill)
        XCTAssertEqual(glyph.resolvedPath?.boundingBox, pendingPathBox)
        XCTAssertEqual(glyph.resolvedLineWidth, 1.4, accuracy: 0.0001)
        XCTAssertNil(glyph.resolvedFillColor, "ring is hollow")
    }

    // MARK: - Ring geometry: strokeBorder inset keeps stroke inside the frame

    func testRingPathInsetByHalfStrokeWidth() {
        // strokeBorder reproduced: ellipse inset by strokeWidth/2 (= 0.7) on
        // each edge → bbox origin (0.7, 0.7), size (12.6, 12.6) at a 14×14 box.
        let glyph = TodoStatusGlyphView()
        glyph.frame = NSRect(x: 0, y: 0, width: 14, height: 14)
        glyph.setState(.pending, muted: false)
        glyph.layoutSubtreeIfNeeded()

        let bbox = try? XCTUnwrap(glyph.resolvedPath?.boundingBox)
        if let bbox {
            XCTAssertEqual(bbox.origin.x, 0.7, accuracy: 0.05)
            XCTAssertEqual(bbox.origin.y, 0.7, accuracy: 0.05)
            XCTAssertEqual(bbox.width, 12.6, accuracy: 0.05)
            XCTAssertEqual(bbox.height, 12.6, accuracy: 0.05)
        }

        // The static helper agrees.
        let staticBox = TodoStatusGlyphView.ringPath(in: NSRect(x: 0, y: 0, width: 14, height: 14))
            .boundingBox
        XCTAssertEqual(staticBox.origin.x, 0.7, accuracy: 0.05)
        XCTAssertEqual(staticBox.width, 12.6, accuracy: 0.05)
    }

    // MARK: - One reused shape layer (no per-state recreation)

    func testSingleShapeLayerReusedAcrossStates() {
        let glyph = TodoStatusGlyphView()
        let initial = glyph.resolvedShapeLayer
        glyph.setState(.inProgress, muted: false)
        XCTAssertTrue(glyph.resolvedShapeLayer === initial)
        glyph.setState(.completed, muted: false)
        XCTAssertTrue(glyph.resolvedShapeLayer === initial)
        glyph.setState(.pending, muted: true)
        XCTAssertTrue(
            glyph.resolvedShapeLayer === initial,
            "one CAShapeLayer must be reused across every setState")
    }

    // MARK: - Footprint invariance across all four combos

    func testFootprintInvariantAcrossAllStates() {
        let glyph = TodoStatusGlyphView()
        let frame = NSRect(x: 0, y: 0, width: 14, height: 14)
        glyph.frame = frame

        let combos: [(TodoEntry.Status, Bool)] = [
            (.pending, false),
            (.inProgress, false),
            (.inProgress, true),
            (.completed, false),
            (.completed, true),
            (.pending, true),
        ]
        for (status, muted) in combos {
            glyph.setState(status, muted: muted)
            glyph.layoutSubtreeIfNeeded()
            XCTAssertEqual(glyph.frame, frame, "view frame must not shift on state flip")
            XCTAssertEqual(
                glyph.resolvedShapeLayer.frame, glyph.bounds,
                "shape layer must fill bounds for \(status) muted=\(muted)")
        }
    }

    // MARK: - R14: appearance-flip cgColor re-resolve

    func testInProgressColorReResolvesOnAppearanceFlip() {
        // Live inProgress paints controlAccentColor. Unlike secondaryLabelColor,
        // the system accent often resolves to the SAME RGB across appearances
        // (it's the user's chosen accent), so a naive light != dark assertion is
        // flaky. Instead prove the value TRACKS effectiveAppearance — after each
        // flip the layer's stroke equals the accent freshly resolved against the
        // current appearance (i.e. it is not frozen at first-paint).
        let glyph = TodoStatusGlyphView(status: .inProgress, muted: false)

        func accent(_ appearance: NSAppearance) -> CGColor {
            var out = NSColor.controlAccentColor.cgColor
            appearance.performAsCurrentDrawingAppearance {
                out = NSColor.controlAccentColor.cgColor
            }
            return out
        }

        let light = NSAppearance(named: .aqua)!
        glyph.appearance = light
        glyph.viewDidChangeEffectiveAppearance()
        XCTAssertEqual(
            glyph.resolvedStrokeColor, accent(glyph.effectiveAppearance),
            "inProgress stroke must equal the accent resolved against aqua")

        let dark = NSAppearance(named: .darkAqua)!
        glyph.appearance = dark
        glyph.viewDidChangeEffectiveAppearance()
        XCTAssertEqual(
            glyph.resolvedStrokeColor, accent(glyph.effectiveAppearance),
            "inProgress stroke must re-resolve against darkAqua (R14, not frozen)")
    }

    func testCompletedColorReResolvesOnAppearanceFlip() {
        // Completed paints secondaryLabelColor (appearance-dynamic) as fill.
        let glyph = TodoStatusGlyphView(status: .completed, muted: false)

        glyph.appearance = NSAppearance(named: .aqua)
        glyph.viewDidChangeEffectiveAppearance()
        let light = glyph.resolvedFillColor

        glyph.appearance = NSAppearance(named: .darkAqua)
        glyph.viewDidChangeEffectiveAppearance()
        let dark = glyph.resolvedFillColor

        XCTAssertNotNil(light)
        XCTAssertNotNil(dark)
        XCTAssertNotEqual(
            light, dark,
            "completed fill must re-resolve on appearance flip (R14)")
    }

    // MARK: - Color mapping (accent vs secondary)

    func testColorMappingMatchesSwiftUI() {
        let glyph = TodoStatusGlyphView()
        glyph.appearance = NSAppearance(named: .aqua)
        glyph.viewDidChangeEffectiveAppearance()

        func resolved(_ color: NSColor) -> CGColor {
            var out = color.cgColor
            glyph.effectiveAppearance.performAsCurrentDrawingAppearance { out = color.cgColor }
            return out
        }

        // pending → secondary
        glyph.setState(.pending, muted: false)
        XCTAssertEqual(glyph.resolvedStrokeColor, resolved(.secondaryLabelColor))

        // live inProgress → accent
        glyph.setState(.inProgress, muted: false)
        XCTAssertEqual(glyph.resolvedStrokeColor, resolved(.controlAccentColor))

        // muted inProgress → secondary (the quiet chrome variant)
        glyph.setState(.inProgress, muted: true)
        XCTAssertEqual(glyph.resolvedStrokeColor, resolved(.secondaryLabelColor))

        // completed → secondary (fill)
        glyph.setState(.completed, muted: false)
        XCTAssertEqual(glyph.resolvedFillColor, resolved(.secondaryLabelColor))
    }

    // MARK: - intrinsicContentSize is noIntrinsicMetric on both axes

    func testIntrinsicContentSizeIsNoIntrinsicMetric() {
        let glyph = TodoStatusGlyphView()
        XCTAssertEqual(glyph.intrinsicContentSize.width, NSView.noIntrinsicMetric)
        XCTAssertEqual(glyph.intrinsicContentSize.height, NSView.noIntrinsicMetric)
    }

    // MARK: - Idempotence

    func testSetStateIdempotentForSameInput() {
        let glyph = TodoStatusGlyphView(status: .inProgress, muted: false)
        let firstAnim = glyph.resolvedRotationAnimation
        glyph.setState(.inProgress, muted: false)  // no-op
        // Same animation instance preserved (not restacked).
        XCTAssertTrue(glyph.resolvedRotationAnimation === firstAnim)
    }
}
