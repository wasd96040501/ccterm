import AppKit
import XCTest

@testable import ccterm

/// CI-gate measurement test (non-snapshot → runs on the default suite) for the
/// shared `PermissionDecisionButtonView` (migration plan §4.4, §9). Drives the
/// REAL production object — the role→color mapping, the hover flip through the
/// real `NSTrackingArea` mouseEntered/Exited path, and the click action — and
/// asserts on the resolved layer / label colors against the SwiftUI source
/// (`PermissionCardView.swift:296-321`).
///
/// Colors are compared in sRGB component space (CGColor identity is fragile
/// across color spaces) with a small tolerance; expected colors are resolved
/// under the SAME effective appearance the button resolves against.
@MainActor
final class PermissionDecisionButtonTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    /// Mount a button in an aqua (light) container and lay it out so layer
    /// geometry / colors are resolved. The appearance is forced on the BUTTON
    /// itself (not just the container) so its `effectiveAppearance` stays
    /// resolved even after the throwaway container is released — otherwise the
    /// button reverts to the (dark) XCTest host default and a later color read
    /// disagrees with the value it resolved while mounted.
    private func mounted(
        _ button: PermissionDecisionButtonView,
        appearance: NSAppearance.Name = .aqua,
        width: CGFloat = 120
    ) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 40))
        container.appearance = NSAppearance(named: appearance)
        button.appearance = NSAppearance(named: appearance)
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        return container
    }

    /// Resolve an `NSColor` to sRGB components against a forced appearance,
    /// anchored on the SAME view the production color was resolved against (its
    /// `effectiveAppearance.performAsCurrentDrawingAppearance`). Anchoring on the
    /// production view — rather than a throwaway `NSView` or a bare
    /// `NSAppearance(named:)` — is the only reliable path under the XCTest host,
    /// whose default `NSApp.effectiveAppearance` otherwise leaks into a dynamic
    /// catalog color's resolution (observed: `labelColor` reading dark even when
    /// a fresh view forced `.aqua`). This is exactly how the production button
    /// resolves its own colors, so the expectation tracks production 1:1.
    private func rgba(
        _ color: NSColor, like view: NSView
    ) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var cg: CGColor = color.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            cg = color.cgColor
        }
        return rgba(cg)
    }

    /// Resolve a `CGColor` to sRGB components.
    private func rgba(_ cg: CGColor) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let ns = NSColor(cgColor: cg) ?? .clear
        let c = ns.usingColorSpace(.sRGB) ?? ns
        return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    private func assertColorsEqual(
        _ a: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat),
        _ b: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat),
        accuracy: CGFloat = 0.02,
        _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.r, b.r, accuracy: accuracy, "\(message) (R)", file: file, line: line)
        XCTAssertEqual(a.g, b.g, accuracy: accuracy, "\(message) (G)", file: file, line: line)
        XCTAssertEqual(a.b, b.b, accuracy: accuracy, "\(message) (B)", file: file, line: line)
        XCTAssertEqual(a.a, b.a, accuracy: accuracy, "\(message) (A)", file: file, line: line)
    }

    // MARK: - Dimensions / shape

    func testHeightIs24AndCornerRadiusIs8() {
        let button = PermissionDecisionButtonView(title: "Deny", role: .destructive)
        let container = mounted(button)
        XCTAssertEqual(
            button.frame.height, 24, accuracy: 0.5,
            "The button's height constraint pins it at 24pt (PermissionCardView.swift:280).")
        _ = container
        XCTAssertEqual(
            button.resolvedCornerRadius, 8, accuracy: 0.5,
            "The fill layer rounds at 8pt continuous (PermissionCardView.swift:282).")
    }

    // MARK: - Role → rest colors
    //
    // Colors are asserted by two appearance-robust facts: (a) the EXACT alpha,
    // which is the role-distinguishing source constant
    // (`PermissionCardView.swift:304-321`), and (b) the hue FAMILY via component
    // relationships (destructive is red-dominant systemRed; secondary is a
    // desaturated gray labelColor; primary matches controlAccentColor, which is
    // appearance-stable so a direct compare is safe). This sidesteps the XCTest
    // host's unreliable resolution of dynamic catalog colors to a specific RGB
    // (observed: labelColor reading white under aqua) while still proving the
    // production mapping is correct.

    func testPrimaryRestColors() {
        let button = PermissionDecisionButtonView(title: "Allow always", role: .primary)
        _ = mounted(button)
        let fill = rgba(button.resolvedFillColor!)
        // Fill alpha = 1.0 (rest), and the RGB matches controlAccentColor
        // (appearance-stable → direct compare is reliable).
        XCTAssertEqual(fill.a, 1.0, accuracy: 0.02, "Primary rest fill alpha = 1.0.")
        let accent = rgba(.controlAccentColor, like: button)
        XCTAssertEqual(fill.r, accent.r, accuracy: 0.05, "Primary fill = controlAccentColor (R).")
        XCTAssertEqual(fill.g, accent.g, accuracy: 0.05, "Primary fill = controlAccentColor (G).")
        XCTAssertEqual(fill.b, accent.b, accuracy: 0.05, "Primary fill = controlAccentColor (B).")
        // Text = white.
        let text = rgba(button.resolvedTextColor!.cgColor)
        XCTAssertEqual(text.r, 1.0, accuracy: 0.02, "Primary text = white (R).")
        XCTAssertEqual(text.g, 1.0, accuracy: 0.02, "Primary text = white (G).")
        XCTAssertEqual(text.b, 1.0, accuracy: 0.02, "Primary text = white (B).")
        // Stroke = clear (alpha 0).
        XCTAssertEqual(
            rgba(button.resolvedStrokeColor!).a, 0, accuracy: 0.02, "Primary stroke is clear.")
    }

    func testSecondaryRestColors() {
        let button = PermissionDecisionButtonView(title: "Allow once", role: .secondary)
        _ = mounted(button)
        let fill = rgba(button.resolvedFillColor!)
        // Fill = labelColor@0.04 — exact alpha + desaturated gray (R≈G≈B).
        XCTAssertEqual(fill.a, 0.04, accuracy: 0.005, "Secondary rest fill alpha = 0.04.")
        XCTAssertEqual(fill.r, fill.g, accuracy: 0.02, "labelColor fill is a gray (R≈G).")
        XCTAssertEqual(fill.g, fill.b, accuracy: 0.02, "labelColor fill is a gray (G≈B).")
        // Stroke = separatorColor (opaque-ish gray; assert it is a low-saturation
        // color present at a non-trivial alpha — the separator hairline).
        let stroke = rgba(button.resolvedStrokeColor!)
        XCTAssertEqual(stroke.r, stroke.g, accuracy: 0.05, "separator stroke is a gray (R≈G).")
        XCTAssertGreaterThan(stroke.a, 0, "separator stroke is visible (alpha > 0).")
    }

    func testDestructiveRestColors() {
        let button = PermissionDecisionButtonView(title: "Deny", role: .destructive)
        _ = mounted(button)
        let fill = rgba(button.resolvedFillColor!)
        // Fill = systemRed@0.08 — exact alpha + red-dominant hue.
        XCTAssertEqual(fill.a, 0.08, accuracy: 0.005, "Destructive rest fill alpha = 0.08.")
        XCTAssertGreaterThan(fill.r, fill.g + 0.2, "systemRed fill is red-dominant (R ≫ G).")
        XCTAssertGreaterThan(fill.r, fill.b + 0.2, "systemRed fill is red-dominant (R ≫ B).")
        // Text = systemRed (opaque, red-dominant).
        let text = rgba(button.resolvedTextColor!.cgColor)
        XCTAssertGreaterThan(text.r, text.g + 0.2, "Destructive text is systemRed (R ≫ G).")
        XCTAssertGreaterThan(text.r, text.b + 0.2, "Destructive text is systemRed (R ≫ B).")
        // Stroke = systemRed@0.4 — exact alpha + red-dominant.
        let stroke = rgba(button.resolvedStrokeColor!)
        XCTAssertEqual(stroke.a, 0.4, accuracy: 0.01, "Destructive stroke alpha = 0.4.")
        XCTAssertGreaterThan(stroke.r, stroke.g + 0.2, "Destructive stroke is systemRed (R ≫ G).")
    }

    // MARK: - Hover flip via the real NSTrackingArea entry/exit path

    func testHoverFlipsFillForEachRole() {
        // Primary: rest accent@1.0 → hover accent@0.92 (alpha shift only).
        let primary = PermissionDecisionButtonView(title: "Allow always", role: .primary)
        _ = mounted(primary)
        XCTAssertEqual(
            rgba(primary.resolvedFillColor!).a, 1.0, accuracy: 0.02,
            "Primary rest fill alpha = 1.0.")
        primary.mouseEntered(with: dummyEvent())
        XCTAssertTrue(primary.hovering, "mouseEntered toggles the hover flag.")
        XCTAssertEqual(
            rgba(primary.resolvedFillColor!).a, 0.92, accuracy: 0.02,
            "Primary hover fill = controlAccentColor@0.92.")
        XCTAssertTrue(
            primary.hasPendingHoverAnimation,
            "A hover transition adds a real CABasicAnimation under the hoverFill "
                + "key (0.1s linear, PermissionCardView.swift:293).")
        primary.mouseExited(with: dummyEvent())
        XCTAssertFalse(primary.hovering, "mouseExited clears the hover flag.")
        XCTAssertEqual(
            rgba(primary.resolvedFillColor!).a, 1.0, accuracy: 0.02,
            "Primary returns to controlAccentColor@1.0 on exit.")

        // Secondary: 0.04 → 0.10.
        let secondary = PermissionDecisionButtonView(title: "Allow once", role: .secondary)
        _ = mounted(secondary)
        XCTAssertEqual(
            rgba(secondary.resolvedFillColor!).a, 0.04, accuracy: 0.005,
            "Secondary rest fill alpha = 0.04.")
        secondary.mouseEntered(with: dummyEvent())
        XCTAssertEqual(
            rgba(secondary.resolvedFillColor!).a, 0.10, accuracy: 0.005,
            "Secondary hover fill = labelColor@0.10.")

        // Destructive: 0.08 → 0.16.
        let destructive = PermissionDecisionButtonView(title: "Deny", role: .destructive)
        _ = mounted(destructive)
        XCTAssertEqual(
            rgba(destructive.resolvedFillColor!).a, 0.08, accuracy: 0.005,
            "Destructive rest fill alpha = 0.08.")
        destructive.mouseEntered(with: dummyEvent())
        XCTAssertEqual(
            rgba(destructive.resolvedFillColor!).a, 0.16, accuracy: 0.005,
            "Destructive hover fill = systemRed@0.16.")
        // And it stays red-dominant under hover.
        let hoverFill = rgba(destructive.resolvedFillColor!)
        XCTAssertGreaterThan(
            hoverFill.r, hoverFill.g + 0.2, "Destructive hover fill stays systemRed (R ≫ G).")
    }

    func testRestStateWriteDoesNotAnimate() {
        // The first paint (init) must NOT animate — only deliberate hover does
        // (animation-duration-parity risk). No hover animation is pending after
        // init: the rest-state write snaps under a disabled CATransaction and
        // adds no `hoverFill` CABasicAnimation.
        let button = PermissionDecisionButtonView(title: "Deny", role: .destructive)
        _ = mounted(button)
        XCTAssertFalse(
            button.hasPendingHoverAnimation,
            "Initial / rest-state color writes snap (disabled CATransaction), never animate.")
    }

    // MARK: - Appearance flip re-resolves the dynamic colors (R14)

    func testAppearanceFlipReResolvesDynamicFill() {
        // Use the secondary role (labelColor-based): labelColor flips from
        // near-black (light) to near-white (dark), so the production fill RGB
        // must change on the flip — proving the cgColor was re-resolved, not
        // frozen (R14). A production-to-production comparison sidesteps the
        // XCTest dynamic-color resolution quirk entirely.
        let button = PermissionDecisionButtonView(title: "Allow once", role: .secondary)
        let container = mounted(button, appearance: .aqua)
        let lightFill = rgba(button.resolvedFillColor!)

        // Flip the button's own forced appearance (mounted() pins it on the
        // button so it survives container release).
        button.appearance = NSAppearance(named: .darkAqua)
        container.appearance = NSAppearance(named: .darkAqua)
        // viewDidChangeEffectiveAppearance fires on the appearance flip.
        button.layoutSubtreeIfNeeded()
        let darkFill = rgba(button.resolvedFillColor!)

        let channelDelta =
            abs(lightFill.r - darkFill.r) + abs(lightFill.g - darkFill.g)
            + abs(lightFill.b - darkFill.b)
        XCTAssertGreaterThan(
            channelDelta, 0.3,
            "The fill cgColor must change between aqua and darkAqua (R14 — the "
                + "dynamic labelColor / accent are re-resolved on viewDidChangeEffectiveAppearance).")
    }

    // MARK: - Click action

    func testClickFiresOnClickOnceOnMouseUpInside() {
        let button = PermissionDecisionButtonView(title: "Deny", role: .destructive)
        var fired = 0
        button.onClick = { fired += 1 }
        let window = windowed(button)
        defer {
            window.contentView = nil
            window.close()
        }
        let centerInWindow = button.convert(
            NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        button.mouseDown(with: mouseEvent(.leftMouseDown, at: centerInWindow, in: window))
        button.mouseUp(with: mouseEvent(.leftMouseUp, at: centerInWindow, in: window))
        XCTAssertEqual(fired, 1, "A mouse-up inside the pill fires onClick exactly once.")
    }

    func testMouseUpOutsideDoesNotFire() {
        let button = PermissionDecisionButtonView(title: "Deny", role: .destructive)
        var fired = 0
        button.onClick = { fired += 1 }
        let window = windowed(button)
        defer {
            window.contentView = nil
            window.close()
        }
        let centerInWindow = button.convert(
            NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        button.mouseDown(with: mouseEvent(.leftMouseDown, at: centerInWindow, in: window))
        let outside = NSPoint(x: centerInWindow.x + 500, y: centerInWindow.y + 500)
        button.mouseUp(with: mouseEvent(.leftMouseUp, at: outside, in: window))
        XCTAssertEqual(fired, 0, "A mouse-up outside the pill must NOT fire onClick.")
    }

    /// The role→callback wiring the chrome button row assembles: Deny→onDeny
    /// (destructive), Allow once→onAllowOnce (secondary), Allow always→
    /// onAllowAlways (primary) (PermissionCardView.swift:132-148). Assemble the
    /// three buttons exactly as the row does and assert each fires its own
    /// callback.
    func testChromeRowWiringFiresCorrectCallbackPerButton() {
        var denied = 0
        var allowedOnce = 0
        var allowedAlways = 0
        let deny = PermissionDecisionButtonView(
            title: "Deny", role: .destructive, onClick: { denied += 1 })
        let allowOnce = PermissionDecisionButtonView(
            title: "Allow once", role: .secondary, onClick: { allowedOnce += 1 })
        let allowAlways = PermissionDecisionButtonView(
            title: "Allow always", role: .primary, onClick: { allowedAlways += 1 })

        for button in [deny, allowOnce, allowAlways] {
            let window = windowed(button)
            defer {
                window.contentView = nil
                window.close()
            }
            let center = button.convert(
                NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            button.mouseDown(with: mouseEvent(.leftMouseDown, at: center, in: window))
            button.mouseUp(with: mouseEvent(.leftMouseUp, at: center, in: window))
        }
        XCTAssertEqual(denied, 1, "Deny (destructive) → onDeny.")
        XCTAssertEqual(allowedOnce, 1, "Allow once (secondary) → onAllowOnce.")
        XCTAssertEqual(allowedAlways, 1, "Allow always (primary) → onAllowAlways.")
    }

    // MARK: - Event scaffolding

    private func dummyEvent() -> NSEvent {
        NSEvent.mouseEvent(
            with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
    }

    private func windowed(_ button: PermissionDecisionButtonView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 200, height: 80),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        window.contentView = container
        window.ccterm_orderFrontForTesting()
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        return window
    }

    private func mouseEvent(
        _ type: NSEvent.EventType, at locationInWindow: NSPoint, in window: NSWindow
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: locationInWindow, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }
}
