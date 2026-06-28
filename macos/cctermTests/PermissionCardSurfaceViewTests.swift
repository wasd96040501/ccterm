import AppKit
import XCTest

@testable import ccterm

/// CI-gate measurement test (non-snapshot) for `PermissionCardSurfaceView`
/// (migration plan §4.4-1, §9). The card surface MUST be OPAQUE — the §4.4-1
/// anti-bleed invariant — with its own shadow params, NOT the bar's glass.
/// Drives the real production object and asserts on resolved layer state.
@MainActor
final class PermissionCardSurfaceViewTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func mounted(
        _ surface: PermissionCardSurfaceView,
        appearance: NSAppearance.Name = .aqua,
        size: CGSize = CGSize(width: 400, height: 200)
    ) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.appearance = NSAppearance(named: appearance)
        // Force on the surface itself so its effectiveAppearance survives a
        // container release under the XCTest host (see PermissionDecisionButtonTests).
        surface.appearance = NSAppearance(named: appearance)
        surface.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        return container
    }

    private func rgba(_ cg: CGColor) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let ns = NSColor(cgColor: cg) ?? .clear
        let c = ns.usingColorSpace(.sRGB) ?? ns
        return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    /// Resolve an `NSColor` to sRGB anchored on the SAME view the production
    /// color was resolved against — the only reliable path under the XCTest
    /// host (a bare `NSAppearance(named:).performAsCurrentDrawingAppearance`
    /// leaks the host's default appearance into dynamic catalog colors).
    private func rgba(
        _ color: NSColor, like view: NSView
    ) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var cg: CGColor = color.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            cg = color.cgColor
        }
        return rgba(cg)
    }

    // MARK: - §4.4-1 BLOCKER: the fill is fully OPAQUE

    func testFillIsFullyOpaqueControlBackgroundColor() {
        let surface = PermissionCardSurfaceView()
        _ = mounted(surface)
        let fill = try? XCTUnwrap(surface.resolvedFillColor)
        let comps = rgba(fill!)
        XCTAssertEqual(
            comps.a, 1.0, accuracy: 0.001,
            "The card fill MUST be fully opaque (§4.4-1 anti-bleed invariant) — "
                + "the bar's glass was bleeding through and making diffs unreadable.")
        // And it tracks controlBackgroundColor (resolved against the surface's
        // own appearance — see `rgba(_:like:)`).
        let expected = rgba(.controlBackgroundColor, like: surface)
        XCTAssertEqual(comps.r, expected.r, accuracy: 0.02, "Fill = controlBackgroundColor (R).")
        XCTAssertEqual(comps.g, expected.g, accuracy: 0.02, "Fill = controlBackgroundColor (G).")
        XCTAssertEqual(comps.b, expected.b, accuracy: 0.02, "Fill = controlBackgroundColor (B).")
    }

    // MARK: - Geometry

    func testCornerRadiusIs16() {
        let surface = PermissionCardSurfaceView()
        _ = mounted(surface)
        XCTAssertEqual(
            surface.resolvedCornerRadius, 16, accuracy: 0.5,
            "Card corner radius = 16 (PermissionCardView.cornerRadius).")
        XCTAssertTrue(
            surface.fillCornerCurveIsContinuous,
            "Card fill uses a continuous corner curve (.continuous).")
    }

    func testStrokeIsSeparatorColorAtHalfPointLineWidth() {
        let surface = PermissionCardSurfaceView()
        _ = mounted(surface)
        XCTAssertEqual(
            PermissionCardSurfaceView.strokeLineWidth, 0.5,
            "The separator stroke is 0.5pt (PermissionCardView.swift:246).")
        let stroke = rgba(try! XCTUnwrap(surface.resolvedStrokeColor))
        let expected = rgba(.separatorColor, like: surface)
        XCTAssertEqual(stroke.r, expected.r, accuracy: 0.03, "Stroke = separatorColor (R).")
        XCTAssertEqual(stroke.g, expected.g, accuracy: 0.03, "Stroke = separatorColor (G).")
        XCTAssertEqual(stroke.b, expected.b, accuracy: 0.03, "Stroke = separatorColor (B).")
        XCTAssertEqual(stroke.a, expected.a, accuracy: 0.05, "Stroke = separatorColor (A).")
    }

    // MARK: - Shadow params (DIFFER from BarSurfaceView)

    func testShadowOpacityIsDarkAwareWithCardParams() {
        // Light: 0.12.
        let light = PermissionCardSurfaceView()
        _ = mounted(light, appearance: .aqua)
        XCTAssertEqual(
            light.resolvedShadowOpacity, 0.12, accuracy: 0.001,
            "Light shadow opacity = 0.12 (PermissionCardView.swift:249).")

        // Dark: 0.35.
        let dark = PermissionCardSurfaceView()
        let container = mounted(dark, appearance: .darkAqua)
        _ = container
        XCTAssertEqual(
            dark.resolvedShadowOpacity, 0.35, accuracy: 0.001,
            "Dark shadow opacity = 0.35 (PermissionCardView.swift:249).")

        // Radius 10, offset height -4 (SwiftUI y:+4).
        XCTAssertEqual(light.resolvedShadowRadius, 10, accuracy: 0.5, "Shadow radius = 10.")
        XCTAssertEqual(
            light.resolvedShadowOffset.height, -4, accuracy: 0.5,
            "SwiftUI y:+4 → CALayer shadowOffset.height -4.")
    }

    func testShadowOpacityReResolvesOnAppearanceFlip() {
        let surface = PermissionCardSurfaceView()
        let container = mounted(surface, appearance: .aqua)
        XCTAssertEqual(surface.resolvedShadowOpacity, 0.12, accuracy: 0.001)
        // The surface has its own forced appearance (mounted() pins it); flip it
        // directly so viewDidChangeEffectiveAppearance fires.
        surface.appearance = NSAppearance(named: .darkAqua)
        container.appearance = NSAppearance(named: .darkAqua)
        surface.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            surface.resolvedShadowOpacity, 0.35, accuracy: 0.001,
            "Shadow opacity re-resolves to the dark value on appearance flip (R14).")
    }

    func testShadowPathTracksRoundedSilhouette() {
        let surface = PermissionCardSurfaceView()
        _ = mounted(surface)
        XCTAssertNotNil(
            surface.resolvedShadowPath,
            "The shadow follows a continuous-rounded silhouette, not square bounds.")
    }

    // MARK: - Window-collapse guard (R1)

    func testPublishesNoIntrinsicMetricBothAxes() {
        let surface = PermissionCardSurfaceView()
        XCTAssertEqual(
            surface.intrinsicContentSize.width, NSView.noIntrinsicMetric,
            "Surface width = noIntrinsicMetric (R1 — can't leak fittingSize).")
        XCTAssertEqual(
            surface.intrinsicContentSize.height, NSView.noIntrinsicMetric,
            "Surface height = noIntrinsicMetric (the card content drives the size).")
    }
}
