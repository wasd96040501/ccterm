import AppKit
import XCTest

@testable import ccterm

/// CI-gate (non-snapshot) tests for `ProgressRingLayer` — the AppKit
/// replacement for the SwiftUI `ProgressRingView`. These run on the
/// unfiltered `make test-unit` suite and drive the real production object:
///
/// - the fraction→`strokeEnd` mapping (clamp BEFORE divide, plan §4.2 /
///   `ProgressRingView.swift:20`),
/// - the `ringColor` threshold-walk selection (`ProgressRingView.swift:28-33`),
/// - `lineWidth` applied to **both** the track and the progress layer,
/// - the shared circle path's centering / inset (radius = `(min(w,h) -
///   lineWidth)/2`, centered in `bounds` — survives a non-`size` frame),
/// - `intrinsicContentSize == size × size`,
/// - the appearance-flip cgColor re-resolve (the `CALayer.cgColor`-freeze
///   hazard, plan §4.2-3 / R14),
/// - the round line cap on the progress arc.
@MainActor
final class ProgressRingLayerTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - fraction → strokeEnd (the load-bearing mapping)

    func testStrokeEndTracksClampedPercentAcrossRange() {
        // (percent, expected strokeEnd) — clamp to [0,100] then /100.
        let cases: [(Double, CGFloat)] = [
            (-10, 0),
            (0, 0),
            (35, 0.35),
            (70, 0.70),
            (90, 0.90),
            (95, 0.95),
            (100, 1.0),
            (150, 1.0),
        ]
        let ring = ProgressRingLayer()
        for (percent, expected) in cases {
            ring.percent = percent
            XCTAssertEqual(
                ring.resolvedStrokeEnd, expected, accuracy: 0.0001,
                "percent \(percent) → strokeEnd \(expected)")
        }
    }

    func testStrokeEndAtConstructionMatchesInitialPercent() {
        // Seeded once in init, without animation — the initial percent is
        // geometry, not a user-driven change.
        let ring = ProgressRingLayer(percent: 42)
        XCTAssertEqual(ring.resolvedStrokeEnd, 0.42, accuracy: 0.0001)
    }

    func testStaticStrokeEndHelperClampsBeforeDivide() {
        XCTAssertEqual(ProgressRingLayer.strokeEnd(for: -5), 0, accuracy: 0.0001)
        XCTAssertEqual(ProgressRingLayer.strokeEnd(for: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(ProgressRingLayer.strokeEnd(for: 50), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ProgressRingLayer.strokeEnd(for: 100), 1.0, accuracy: 0.0001)
        XCTAssertEqual(ProgressRingLayer.strokeEnd(for: 250), 1.0, accuracy: 0.0001)
    }

    // MARK: - ringColor threshold selection (ProgressRingView.swift:28-33)

    func testRingColorThresholdSelectionMatchesSwiftUI() {
        let thresholds = ProgressRingLayer.defaultColorThresholds()
        // [0,70) → accent
        XCTAssertEqual(ProgressRingLayer.ringColor(percent: 0, thresholds: thresholds), .controlAccentColor)
        XCTAssertEqual(ProgressRingLayer.ringColor(percent: 69.9, thresholds: thresholds), .controlAccentColor)
        // [70,90) → orange (70 is NOT < 70, falls past the accent pair)
        XCTAssertEqual(ProgressRingLayer.ringColor(percent: 70, thresholds: thresholds), .systemOrange)
        XCTAssertEqual(ProgressRingLayer.ringColor(percent: 89.9, thresholds: thresholds), .systemOrange)
        // [90,100] → red (90 NOT < 90; 100 NOT < 100 → falls through to last)
        XCTAssertEqual(ProgressRingLayer.ringColor(percent: 90, thresholds: thresholds), .systemRed)
        XCTAssertEqual(ProgressRingLayer.ringColor(percent: 100, thresholds: thresholds), .systemRed)
        // Over-cap still red (falls through to last pair).
        XCTAssertEqual(ProgressRingLayer.ringColor(percent: 150, thresholds: thresholds), .systemRed)
    }

    func testRingColorEmptyLadderFallsBackToAccent() {
        XCTAssertEqual(ProgressRingLayer.ringColor(percent: 50, thresholds: []), .controlAccentColor)
    }

    // MARK: - lineWidth applied to both layers

    func testDefaultLineWidthAppliedToBothLayers() {
        let ring = ProgressRingLayer()
        XCTAssertEqual(ring.resolvedTrackLineWidth, ProgressRingLayer.defaultLineWidth, accuracy: 0.0001)
        XCTAssertEqual(ring.resolvedProgressLineWidth, ProgressRingLayer.defaultLineWidth, accuracy: 0.0001)
        // Default is verbatim from ProgressRingView.swift:10.
        XCTAssertEqual(ProgressRingLayer.defaultLineWidth, 2.0, accuracy: 0.0001)
    }

    func testCustomLineWidthAppliedToBothLayers() {
        let ring = ProgressRingLayer(lineWidth: 4)
        XCTAssertEqual(ring.resolvedTrackLineWidth, 4, accuracy: 0.0001)
        XCTAssertEqual(ring.resolvedProgressLineWidth, 4, accuracy: 0.0001)

        // Mutating after init re-applies to both.
        ring.lineWidth = 3
        XCTAssertEqual(ring.resolvedTrackLineWidth, 3, accuracy: 0.0001)
        XCTAssertEqual(ring.resolvedProgressLineWidth, 3, accuracy: 0.0001)
    }

    // MARK: - Path bounds / centering (guards radius + bounds-not-size)

    func testRingPathCentersInBoundsWithLineWidthInset() {
        // A size-12 ring wrapped in a 22×22 frame (ContextRingButton.swift:19):
        // the path must center in BOUNDS, not assume `size`. radius =
        // (min(22,22) - 2) / 2 = 10, center (11,11) → bbox origin (1,1) size
        // (20,20).
        let ring = ProgressRingLayer(lineWidth: 2, size: 12)
        ring.frame = NSRect(x: 0, y: 0, width: 22, height: 22)
        ring.layoutSubtreeIfNeeded()

        let bbox = try? XCTUnwrap(ring.resolvedRingPathBoundingBox)
        XCTAssertNotNil(bbox)
        if let bbox {
            XCTAssertEqual(bbox.origin.x, 1, accuracy: 0.5)
            XCTAssertEqual(bbox.origin.y, 1, accuracy: 0.5)
            XCTAssertEqual(bbox.width, 20, accuracy: 0.5)
            XCTAssertEqual(bbox.height, 20, accuracy: 0.5)
        }
    }

    func testRingPathCentersAtNativeSizeFrame() {
        // At the native 12×12 frame: radius = (12 - 2)/2 = 5, center (6,6) →
        // bbox origin (1,1) size (10,10).
        let ring = ProgressRingLayer(lineWidth: 2, size: 12)
        ring.frame = NSRect(x: 0, y: 0, width: 12, height: 12)
        ring.layoutSubtreeIfNeeded()

        let bbox = try? XCTUnwrap(ring.resolvedRingPathBoundingBox)
        if let bbox {
            XCTAssertEqual(bbox.origin.x, 1, accuracy: 0.5)
            XCTAssertEqual(bbox.origin.y, 1, accuracy: 0.5)
            XCTAssertEqual(bbox.width, 10, accuracy: 0.5)
            XCTAssertEqual(bbox.height, 10, accuracy: 0.5)
        }
    }

    func testTrackAndProgressShareTheSamePath() {
        // Both circles draw the same geometry (SwiftUI stacks two Circles of
        // the same frame); only the trim + cap + color differ. The production
        // code assigns ONE `CGPath` local to both layers, so their bounding
        // boxes must be equal — assert it directly, not by re-deriving.
        let ring = ProgressRingLayer(size: 22)
        ring.frame = NSRect(x: 0, y: 0, width: 22, height: 22)
        ring.layoutSubtreeIfNeeded()

        let progressBox = try? XCTUnwrap(ring.resolvedRingPathBoundingBox)
        let trackBox = try? XCTUnwrap(ring.resolvedTrackPathBoundingBox)
        XCTAssertNotNil(progressBox)
        XCTAssertNotNil(trackBox)
        if let progressBox, let trackBox {
            // Identical inset-centered circle (radius 10 at 22×22 → bbox 20×20).
            XCTAssertEqual(progressBox.width, 20, accuracy: 0.5)
            XCTAssertEqual(progressBox.height, 20, accuracy: 0.5)
            XCTAssertEqual(trackBox, progressBox, "track + progress must share the same path")
        }
    }

    // MARK: - intrinsicContentSize == size × size

    func testIntrinsicContentSizeIsSizeSquaredDefault() {
        let ring = ProgressRingLayer()  // default size 12
        XCTAssertEqual(ring.intrinsicContentSize.width, 12, accuracy: 0.0001)
        XCTAssertEqual(ring.intrinsicContentSize.height, 12, accuracy: 0.0001)
    }

    func testIntrinsicContentSizeIsSizeSquaredExplicit22() {
        let ring = ProgressRingLayer(size: 22)  // popover summary call site
        XCTAssertEqual(ring.intrinsicContentSize.width, 22, accuracy: 0.0001)
        XCTAssertEqual(ring.intrinsicContentSize.height, 22, accuracy: 0.0001)
    }

    func testIntrinsicContentSizeTracksSizeMutation() {
        let ring = ProgressRingLayer(size: 12)
        ring.size = 22
        XCTAssertEqual(ring.intrinsicContentSize.width, 22, accuracy: 0.0001)
        XCTAssertEqual(ring.intrinsicContentSize.height, 22, accuracy: 0.0001)
    }

    // MARK: - Round line cap (ProgressRingView.swift:21)

    func testProgressArcUsesRoundLineCap() {
        let ring = ProgressRingLayer()
        XCTAssertEqual(ring.resolvedProgressLineCap, .round)
    }

    // MARK: - Appearance flip re-resolve (R14 — CALayer.cgColor freeze)

    func testProgressStrokeColorReResolvesOnAppearanceFlip() {
        // Put percent in the orange band so the progress color is the
        // semantic systemOrange (which differs across appearances), then flip
        // the appearance and assert the cgColor was re-resolved (not frozen).
        let ring = ProgressRingLayer(percent: 80)

        ring.appearance = NSAppearance(named: .aqua)
        ring.viewDidChangeEffectiveAppearance()
        let lightProgress = ring.resolvedProgressStrokeColor

        ring.appearance = NSAppearance(named: .darkAqua)
        ring.viewDidChangeEffectiveAppearance()
        let darkProgress = ring.resolvedProgressStrokeColor

        XCTAssertNotNil(lightProgress)
        XCTAssertNotNil(darkProgress)
        // systemOrange resolves to different RGB across appearances; if the
        // cgColor were frozen (the R14 hazard) these would be equal.
        XCTAssertNotEqual(
            lightProgress, darkProgress,
            "progress cgColor must re-resolve on appearance flip")
    }

    func testTrackStrokeColorReResolvesOnAppearanceFlip() {
        // separatorColor is appearance-dynamic; the track must re-resolve too.
        let ring = ProgressRingLayer(percent: 30)

        ring.appearance = NSAppearance(named: .aqua)
        ring.viewDidChangeEffectiveAppearance()
        let lightTrack = ring.resolvedTrackStrokeColor

        ring.appearance = NSAppearance(named: .darkAqua)
        ring.viewDidChangeEffectiveAppearance()
        let darkTrack = ring.resolvedTrackStrokeColor

        XCTAssertNotNil(lightTrack)
        XCTAssertNotNil(darkTrack)
        XCTAssertNotEqual(
            lightTrack, darkTrack,
            "track separatorColor cgColor must re-resolve on appearance flip")
    }

    // MARK: - Color band drives the stroke color on percent change

    func testStrokeColorFollowsBandOnPercentChange() {
        // Drive the production `percent` setter across band boundaries and
        // assert the resolved progress color tracks the band — this is the
        // observable consequence of ringColor selection wired into the layer.
        let ring = ProgressRingLayer(percent: 10)
        ring.appearance = NSAppearance(named: .aqua)
        ring.viewDidChangeEffectiveAppearance()

        func resolved(_ color: NSColor) -> CGColor {
            var out = color.cgColor
            ring.effectiveAppearance.performAsCurrentDrawingAppearance { out = color.cgColor }
            return out
        }

        ring.percent = 10  // already 10 → no-op; set to a fresh accent value
        ring.percent = 30
        XCTAssertEqual(ring.resolvedProgressStrokeColor, resolved(.controlAccentColor))

        ring.percent = 80
        XCTAssertEqual(ring.resolvedProgressStrokeColor, resolved(.systemOrange))

        ring.percent = 96
        XCTAssertEqual(ring.resolvedProgressStrokeColor, resolved(.systemRed))
    }

    // MARK: - Band crossfade animation (parity: SwiftUI animates the color too)

    func testBandCrossingPercentChangeAnimatesStrokeColorWithMatchingTiming() {
        // SwiftUI's `.animation(.easeInOut(0.4), value: percent)` animates the
        // `ringColor` crossfade in the SAME pass as the trim. A band-crossing
        // percent change must therefore install a `strokeColor` animation whose
        // duration + timing match the `strokeEnd` tween.
        //
        // A freshly-constructed ring installs NO animation (init seeds via the
        // animated:false path), so the first percent setter call below is the
        // only animation source — no reset seam needed.
        let ring = ProgressRingLayer(percent: 30)  // accent band, un-animated seed
        XCTAssertNil(ring.resolvedStrokeColorAnimation)

        ring.percent = 80  // accent → orange (band crossing)

        let colorAnim = try? XCTUnwrap(ring.resolvedStrokeColorAnimation)
        XCTAssertNotNil(colorAnim, "band-crossing change must crossfade the stroke color")
        if let colorAnim {
            XCTAssertEqual(
                colorAnim.duration, ProgressRingLayer.animationDuration, accuracy: 0.0001)
            XCTAssertEqual(
                colorAnim.timingFunction, CAMediaTimingFunction(name: .easeInEaseOut))
        }
        // And the arc tween rides the identical timing.
        let endAnim = ring.resolvedStrokeEndAnimation
        XCTAssertNotNil(endAnim)
        if let endAnim, let colorAnim {
            XCTAssertEqual(endAnim.duration, colorAnim.duration, accuracy: 0.0001)
            XCTAssertEqual(endAnim.timingFunction, colorAnim.timingFunction)
        }
    }

    func testIntraBandPercentChangeDoesNotAnimateStrokeColor() {
        // A move WITHIN a band (30→35, both accent) must NOT crossfade the
        // color — SwiftUI re-derives the same `Color`, so no color animation
        // runs (only the trim tweens). Guards against a spurious crossfade.
        let ring = ProgressRingLayer(percent: 30)  // accent band, un-animated seed
        XCTAssertNil(ring.resolvedStrokeColorAnimation)

        ring.percent = 35  // still accent

        XCTAssertNil(
            ring.resolvedStrokeColorAnimation,
            "intra-band move must not crossfade the color")
        // The arc still tweens.
        XCTAssertNotNil(ring.resolvedStrokeEndAnimation)
    }

    func testInitDoesNotAnimateStrokeColor() {
        // Construction seeds the color un-animated (initial percent is
        // geometry, not a user-driven change).
        let ring = ProgressRingLayer(percent: 80)
        XCTAssertNil(ring.resolvedStrokeColorAnimation)
        XCTAssertNil(ring.resolvedStrokeEndAnimation)
    }

    func testAppearanceFlipDoesNotAnimateStrokeColor() {
        // An appearance flip re-resolves the cgColor but must not crossfade it
        // (the band selection is unchanged; the swap is wrapped in a disabled
        // transaction). A fresh ring at a settled percent installs no
        // animation, and the flips below select the SAME band, so no color
        // animation may appear.
        let ring = ProgressRingLayer(percent: 80)  // orange band, un-animated seed
        ring.appearance = NSAppearance(named: .aqua)
        ring.viewDidChangeEffectiveAppearance()
        XCTAssertNil(ring.resolvedStrokeColorAnimation)

        ring.appearance = NSAppearance(named: .darkAqua)
        ring.viewDidChangeEffectiveAppearance()

        XCTAssertNil(
            ring.resolvedStrokeColorAnimation,
            "appearance flip must not crossfade the color")
    }
}
