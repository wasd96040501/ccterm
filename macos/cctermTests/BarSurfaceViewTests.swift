import AppKit
import XCTest

@testable import ccterm

/// CI-gate (non-snapshot) tests for `BarSurfaceView` + `BarSurfaceMask`.
/// These run on the unfiltered `make test-unit` suite and drive the real
/// production object:
///
/// - the window-collapse guard (`intrinsicContentSize == noIntrinsicMetric`
///   on both axes, plan R1),
/// - the `cornerRadius` wiring into the material clip / content clip,
/// - the pure mask geometry (`capInsets`, resizable side, circle clamp),
/// - the appearance re-resolve mechanism (stroke + shadow cgColors change
///   on a dark↔light flip),
/// - backing-scale tracking of the mask helper.
@MainActor
final class BarSurfaceViewTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Window-collapse guard (plan R1)

    func testIntrinsicContentSizeIsNoIntrinsicMetricBothAxes() {
        let surface = BarSurfaceView(cornerRadius: 16)
        XCTAssertEqual(surface.intrinsicContentSize.width, NSView.noIntrinsicMetric)
        XCTAssertEqual(surface.intrinsicContentSize.height, NSView.noIntrinsicMetric)
    }

    func testIntrinsicContentSizeStaysNoIntrinsicMetricAfterCornerRadiusChange() {
        let surface = BarSurfaceView(cornerRadius: 16)
        surface.cornerRadius = 8
        XCTAssertEqual(surface.intrinsicContentSize.width, NSView.noIntrinsicMetric)
        XCTAssertEqual(surface.intrinsicContentSize.height, NSView.noIntrinsicMetric)
    }

    func testIntrinsicContentSizeStaysNoIntrinsicMetricAfterLayoutAtFixedFrame() {
        let surface = BarSurfaceView(cornerRadius: 16)
        surface.frame = NSRect(x: 0, y: 0, width: 200, height: 32)
        surface.layoutSubtreeIfNeeded()
        XCTAssertEqual(surface.intrinsicContentSize.width, NSView.noIntrinsicMetric)
        XCTAssertEqual(surface.intrinsicContentSize.height, NSView.noIntrinsicMetric)
    }

    /// Pinning the surface to a content view (regime B) and laying it out at
    /// a fixed frame must not publish a non-trivial `fittingSize.height` —
    /// the leak that collapses the window.
    func testFittingSizeDoesNotLeakWhenWrappingContent() {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        // A content view that does NOT pin its own height: the surface must
        // not invent a height of its own.
        let surface = BarSurfaceView(cornerRadius: 16)
        surface.setContentView(content)
        surface.frame = NSRect(x: 0, y: 0, width: 200, height: 32)
        surface.layoutSubtreeIfNeeded()
        // fittingSize derives from intrinsic + constraints; with
        // noIntrinsicMetric and no internal required height constraint, the
        // surface contributes no height of its own.
        XCTAssertLessThanOrEqual(surface.fittingSize.height, 1)
    }

    // MARK: - cornerRadius wiring

    func testCornerRadiusReflectedOnMaskedSurface() {
        let surface = BarSurfaceView(cornerRadius: 16)
        surface.frame = NSRect(x: 0, y: 0, width: 200, height: 32)
        surface.layoutSubtreeIfNeeded()

        // The content clip rounds the hosted content to the pill corners;
        // at 200x32 the radius clamps to min(16, 16) = 16.
        XCTAssertEqual(surface.resolvedContentCornerRadius, 16, accuracy: 0.01)
        XCTAssertEqual(surface.contentClipCornerCurveIsContinuous, true)

        if let glassR = surface.glassCornerRadius {
            // macOS 26 glass branch: NSGlassEffectView.cornerRadius tracks.
            XCTAssertEqual(glassR, 16, accuracy: 0.01)
        } else {
            // macOS 14/15 fallback: the resizable maskImage exists, sized
            // from the corner radius.
            XCTAssertNotNil(surface.fallbackMaskImage)
        }
    }

    func testCornerRadiusChangeRetypesetsSurface() {
        let surface = BarSurfaceView(cornerRadius: 16)
        surface.frame = NSRect(x: 0, y: 0, width: 200, height: 64)
        surface.layoutSubtreeIfNeeded()

        surface.cornerRadius = 8
        surface.layoutSubtreeIfNeeded()

        XCTAssertEqual(surface.resolvedContentCornerRadius, 8, accuracy: 0.01)
        if let glassR = surface.glassCornerRadius {
            XCTAssertEqual(glassR, 8, accuracy: 0.01)
        } else {
            // Mask regenerated at the new radius: side == 2*8+1 == 17.
            let side = surface.fallbackMaskImage?.size.width
            XCTAssertEqual(side, BarSurfaceMask.resizableImageSide(cornerRadius: 8))
        }
    }

    func testAttachCircleClampsCornerRadiusToHalfSmallerSide() {
        // Attach button: 32x32, cornerRadius = size/2 = 16 → degenerate
        // circle, no over-rounding.
        let surface = BarSurfaceView(cornerRadius: 16)
        surface.frame = NSRect(x: 0, y: 0, width: 32, height: 32)
        surface.layoutSubtreeIfNeeded()
        XCTAssertEqual(surface.resolvedContentCornerRadius, 16, accuracy: 0.01)

        // A too-large requested radius on a small box still clamps.
        let over = BarSurfaceView(cornerRadius: 100)
        over.frame = NSRect(x: 0, y: 0, width: 32, height: 32)
        over.layoutSubtreeIfNeeded()
        XCTAssertEqual(over.resolvedContentCornerRadius, 16, accuracy: 0.01)
    }

    // MARK: - Mask geometry (pure-math helper)

    func testMaskCapInsetsEqualCornerRadiusOnEveryEdge() {
        let insets = BarSurfaceMask.capInsets(cornerRadius: 16)
        XCTAssertEqual(insets.top, 16)
        XCTAssertEqual(insets.left, 16)
        XCTAssertEqual(insets.bottom, 16)
        XCTAssertEqual(insets.right, 16)
    }

    func testResizableImageSideIsTwiceRadiusPlusOne() {
        XCTAssertEqual(BarSurfaceMask.resizableImageSide(cornerRadius: 16), 33)
        XCTAssertEqual(BarSurfaceMask.resizableImageSide(cornerRadius: 8), 17)
    }

    func testMaskImageIsResizableWithCornerCaps() {
        let img = BarSurfaceMask.maskImage(cornerRadius: 16, scale: 2.0)
        XCTAssertEqual(img.size.width, 33)
        XCTAssertEqual(img.size.height, 33)
        XCTAssertEqual(img.resizingMode, .stretch)
        XCTAssertEqual(img.capInsets.top, 16)
        XCTAssertEqual(img.capInsets.left, 16)
        XCTAssertEqual(img.capInsets.bottom, 16)
        XCTAssertEqual(img.capInsets.right, 16)
    }

    func testMaskHelperRegeneratesAcrossBackingScales() {
        // The logical point size is scale-independent (it's a resizable mask
        // measured in points), but the BACKING bitmap must be rasterized at
        // the requested scale so the rounded edge stays crisp on Retina.
        // Assert the rep's PIXEL dimensions track the scale (load-bearing:
        // this fails if production ignores the `scale` parameter).
        let oneX = BarSurfaceMask.maskImage(cornerRadius: 16, scale: 1.0)
        let twoX = BarSurfaceMask.maskImage(cornerRadius: 16, scale: 2.0)

        // Both share the same logical point size (33 = 2*16 + 1).
        XCTAssertEqual(oneX.size, twoX.size)
        XCTAssertEqual(oneX.size.width, 33)

        let oneRep = try? XCTUnwrap(oneX.representations.first as? NSBitmapImageRep)
        let twoRep = try? XCTUnwrap(twoX.representations.first as? NSBitmapImageRep)
        XCTAssertNotNil(oneRep)
        XCTAssertNotNil(twoRep)

        // 33 logical points → 33 px at 1x, 66 px at 2x.
        XCTAssertEqual(oneRep?.pixelsWide, 33)
        XCTAssertEqual(twoRep?.pixelsWide, 66)
        // The 2x rep has exactly twice the pixels per side of the 1x rep.
        XCTAssertEqual((twoRep?.pixelsWide ?? 0), 2 * (oneRep?.pixelsWide ?? 0))
        XCTAssertEqual((twoRep?.pixelsHigh ?? 0), 2 * (oneRep?.pixelsHigh ?? 0))
    }

    func testContinuousRoundedPathClampsRadius() {
        // An over-large requested radius (100) on a 32x32 rect must clamp to
        // half the smaller side (16) — a circle. Assert that the clamp is
        // load-bearing by comparing the over-large request to the explicit
        // half-side radius: they must produce the SAME path. (A
        // bounding-box-within-bounds check alone is insensitive to removing
        // the clamp, since CGPath self-clamps internally.)
        let rect = CGRect(x: 0, y: 0, width: 32, height: 32)
        let overLarge = BarSurfaceMask.continuousRoundedPath(in: rect, cornerRadius: 100)
        let clampedExplicit = BarSurfaceMask.continuousRoundedPath(in: rect, cornerRadius: 16)
        XCTAssertEqual(overLarge, clampedExplicit, "over-large radius must clamp to half the smaller side")

        // And the clamped path differs from a small-radius path (proving the
        // radius actually drives the geometry).
        let smallRadius = BarSurfaceMask.continuousRoundedPath(in: rect, cornerRadius: 4)
        XCTAssertNotEqual(overLarge, smallRadius)

        // The clamped path stays inside the rect (bounds-safety).
        XCTAssertTrue(rect.insetBy(dx: -0.5, dy: -0.5).contains(overLarge.boundingBox))
    }

    // MARK: - Appearance re-resolve mechanism (§4.2-3, §4.8)

    func testStrokeAndShadowReResolveOnAppearanceFlip() {
        let surface = BarSurfaceView(cornerRadius: 16)
        surface.frame = NSRect(x: 0, y: 0, width: 200, height: 32)

        // Force a dark appearance, drive the re-resolve, snapshot the
        // resolved outputs.
        surface.appearance = NSAppearance(named: .darkAqua)
        surface.viewDidChangeEffectiveAppearance()
        let darkStroke = surface.resolvedStrokeColor
        let darkShadowOpacity = surface.resolvedShadowOpacity

        // Flip to light, drive the re-resolve again.
        surface.appearance = NSAppearance(named: .aqua)
        surface.viewDidChangeEffectiveAppearance()
        let lightStroke = surface.resolvedStrokeColor
        let lightShadowOpacity = surface.resolvedShadowOpacity

        // Stroke is the semantic separatorColor — it differs across
        // appearances, proving the cgColor was re-resolved (not frozen).
        // This inequality is the genuine cgColor-re-resolve gate.
        XCTAssertNotNil(darkStroke)
        XCTAssertNotNil(lightStroke)
        XCTAssertNotEqual(darkStroke, lightStroke, "separatorColor cgColor must re-resolve on flip")

        // Shadow opacity tracks the appearance in both branches (it is
        // recomputed from the appearance bool on every applyShadow):
        //   glass:    0.3 (dark) vs 0.12 (light)
        //   fallback: 0   (dark) vs 0.1  (light)
        // (This asserts the appearance-tracking output, not cgColor freeze —
        // the stroke inequality above is the cgColor-re-resolve proof.)
        XCTAssertNotEqual(
            darkShadowOpacity, lightShadowOpacity,
            "shadow opacity must track the effective appearance")
    }

    func testShadowOffsetUsesFlippedCALayerSign() {
        // SwiftUI y is positive-down; CALayer shadowOffset y is positive-up.
        // The SwiftUI y:4 (glass) / y:1 (fallback) becomes a NEGATIVE height.
        let surface = BarSurfaceView(cornerRadius: 16)
        surface.appearance = NSAppearance(named: .aqua)
        surface.viewDidChangeEffectiveAppearance()
        XCTAssertLessThan(
            surface.resolvedShadowOffset.height, 0,
            "shadow must sit below the surface (negative CALayer y)")
    }

    // MARK: - Shadow opt-out (attach-button parity) + silhouette path

    func testAttachButtonOptsOutOfShadow() {
        // The original AttachButton.surface is flat (no .shadow). A surface
        // built with drawsShadow:false must paint no shadow regardless of
        // appearance — opacity 0 in both light and dark.
        let attach = BarSurfaceView(cornerRadius: 16, drawsShadow: false)

        attach.appearance = NSAppearance(named: .aqua)
        attach.viewDidChangeEffectiveAppearance()
        XCTAssertEqual(attach.resolvedShadowOpacity, 0, "attach button must be shadowless (light)")

        attach.appearance = NSAppearance(named: .darkAqua)
        attach.viewDidChangeEffectiveAppearance()
        XCTAssertEqual(attach.resolvedShadowOpacity, 0, "attach button must be shadowless (dark)")
    }

    func testShadowDrawingSurfaceHasNonZeroOpacity() {
        // The pill / chrome buttons (drawsShadow defaults true) DO paint a
        // shadow — distinguishes the opt-out from a global "no shadow".
        let pill = BarSurfaceView(cornerRadius: 16)
        pill.appearance = NSAppearance(named: .aqua)
        pill.viewDidChangeEffectiveAppearance()
        XCTAssertGreaterThan(pill.resolvedShadowOpacity, 0, "the pill surface must paint a shadow")
    }

    func testShadowPathFollowsRoundedSilhouetteNotBounds() {
        // A pathless shadow traces the rectangular layer bounds; the fix sets
        // layer.shadowPath to the clamped continuous-rounded path so the
        // shadow follows the rounded shape. Assert the path exists and is
        // strictly inset from the corners of the bounds (a rectangular path
        // would touch the corners; a rounded one does not).
        let pill = BarSurfaceView(cornerRadius: 16)
        pill.frame = NSRect(x: 0, y: 0, width: 200, height: 32)
        pill.layoutSubtreeIfNeeded()

        let path = try? XCTUnwrap(pill.resolvedShadowPath)
        XCTAssertNotNil(path)
        // The rounded shadow path must NOT contain the rect's corner point
        // (a bounds-rect path would). At r16 on a 32-tall pill the corner is
        // well outside the rounded silhouette.
        if let path {
            XCTAssertFalse(
                path.contains(CGPoint(x: 0, y: 0)),
                "rounded shadow path must not reach the bounds corner")
            // The center is inside the silhouette.
            XCTAssertTrue(path.contains(CGPoint(x: 100, y: 16)))
        }
    }

    func testAttachCircleShadowPathIsCircular() {
        // The 32x32 attach circle's shadow path (when drawn) must be the
        // circular silhouette, not a square — verify a corner is excluded
        // even though the requested radius equals size/2.
        let attach = BarSurfaceView(cornerRadius: 16)  // drawsShadow default; path is set regardless
        attach.frame = NSRect(x: 0, y: 0, width: 32, height: 32)
        attach.layoutSubtreeIfNeeded()
        let path = try? XCTUnwrap(attach.resolvedShadowPath)
        XCTAssertNotNil(path)
        if let path {
            XCTAssertFalse(path.contains(CGPoint(x: 0, y: 0)), "circle shadow must exclude the corner")
            XCTAssertTrue(path.contains(CGPoint(x: 16, y: 16)), "circle shadow includes the center")
        }
    }

    // MARK: - isBarSurfaceDark helper

    func testIsBarSurfaceDarkResolvesCorrectly() {
        XCTAssertEqual(NSAppearance(named: .darkAqua)?.isBarSurfaceDark, true)
        XCTAssertEqual(NSAppearance(named: .aqua)?.isBarSurfaceDark, false)
    }
}
