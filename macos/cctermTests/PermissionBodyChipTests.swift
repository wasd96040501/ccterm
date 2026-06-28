import AppKit
import XCTest

@testable import ccterm

/// CI-gate measurement test (non-snapshot) for `PermissionBodyChip` (migration
/// plan §4.4, §9) — the rounded-pill chip (Mcp serverChip / TaskAgent chipView).
/// Drives the real production object and asserts on intrinsic size, corner
/// radius, background fill, and the appearance-flip re-resolve.
@MainActor
final class PermissionBodyChipTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func mounted(
        _ chip: PermissionBodyChip, appearance: NSAppearance.Name = .aqua
    ) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        container.appearance = NSAppearance(named: appearance)
        // Force on the chip itself so its effectiveAppearance survives a
        // container release under the XCTest host (see PermissionDecisionButtonTests).
        chip.appearance = NSAppearance(named: appearance)
        chip.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(chip)
        NSLayoutConstraint.activate([
            chip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            chip.centerYAnchor.constraint(equalTo: container.centerYAnchor),
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
    /// color was resolved against — the reliable path under the XCTest host.
    private func rgba(
        _ color: NSColor, like view: NSView
    ) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var cg: CGColor = color.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            cg = color.cgColor
        }
        return rgba(cg)
    }

    // MARK: - Intrinsic size = text + padding (6h, 2v per side → 12h, 4v total)

    func testIntrinsicSizeIsTextPlusPadding() {
        let chip = PermissionBodyChip(text: "linear")
        _ = mounted(chip)
        // Reconstruct the measured text size the same way production does.
        let probe = NSTextField(labelWithString: "linear")
        probe.font = .systemFont(ofSize: PermissionBodyChip.textFontSize, weight: .medium)
        probe.maximumNumberOfLines = 1
        probe.cell?.usesSingleLineMode = true
        probe.lineBreakMode = .byClipping
        let textSize = probe.intrinsicContentSize

        XCTAssertEqual(
            chip.intrinsicContentSize.width,
            textSize.width + 2 * PermissionBodyChip.horizontalPadding, accuracy: 1.0,
            "Chip width = text width + 12pt (6pt horizontal padding each side).")
        XCTAssertEqual(
            chip.intrinsicContentSize.height,
            textSize.height + 2 * PermissionBodyChip.verticalPadding, accuracy: 1.0,
            "Chip height = text height + 4pt (2pt vertical padding each side).")
    }

    func testPaddingConstantsMatchSource() {
        XCTAssertEqual(PermissionBodyChip.horizontalPadding, 6, "6pt horizontal padding per side.")
        XCTAssertEqual(PermissionBodyChip.verticalPadding, 2, "2pt vertical padding per side.")
        XCTAssertEqual(PermissionBodyChip.textFontSize, 10, "size-10 medium text.")
    }

    // MARK: - Corner radius + fill

    func testCornerRadiusIs6() {
        let chip = PermissionBodyChip(text: "ENG")
        _ = mounted(chip)
        XCTAssertEqual(
            chip.resolvedCornerRadius, 6, accuracy: 0.5,
            "Chip background rounds at 6pt continuous (PermissionMcpCardBody.swift:125).")
    }

    func testBackgroundFillIsLabelColorAt006() {
        let chip = PermissionBodyChip(text: "ENG")
        _ = mounted(chip)
        let fill = rgba(try! XCTUnwrap(chip.resolvedBackgroundColor))
        // Appearance-robust: the load-bearing constant is the EXACT alpha (0.06)
        // and the gray hue (labelColor is achromatic → R≈G≈B). A direct RGB
        // compare against an independently-resolved labelColor is unreliable
        // under the XCTest host (dynamic catalog colors mis-resolve to the host
        // default appearance); the R14 re-resolve is proven separately by
        // `testBackgroundFillReResolvesOnAppearanceFlip`.
        XCTAssertEqual(fill.a, 0.06, accuracy: 0.005, "Fill alpha = 0.06 (labelColor@0.06).")
        XCTAssertEqual(fill.r, fill.g, accuracy: 0.02, "labelColor fill is a gray (R≈G).")
        XCTAssertEqual(fill.g, fill.b, accuracy: 0.02, "labelColor fill is a gray (G≈B).")
    }

    func testTextColorIsSecondaryLabel() {
        let chip = PermissionBodyChip(text: "ENG")
        _ = mounted(chip)
        XCTAssertEqual(
            chip.resolvedTextColor, .secondaryLabelColor,
            "Chip text = secondaryLabelColor (SwiftUI .secondary).")
    }

    // MARK: - Appearance flip re-resolves the cgColor (R14)

    func testBackgroundFillReResolvesOnAppearanceFlip() {
        let chip = PermissionBodyChip(text: "ENG")
        let container = mounted(chip, appearance: .aqua)
        let lightFill = rgba(try! XCTUnwrap(chip.resolvedBackgroundColor))

        container.appearance = NSAppearance(named: .darkAqua)
        chip.appearance = NSAppearance(named: .darkAqua)
        chip.layoutSubtreeIfNeeded()
        let darkFill = rgba(try! XCTUnwrap(chip.resolvedBackgroundColor))

        // labelColor resolves to (near) black in light and (near) white in dark,
        // so the RGB must change on flip — proving the cgColor wasn't frozen.
        let channelDelta =
            abs(lightFill.r - darkFill.r) + abs(lightFill.g - darkFill.g)
            + abs(lightFill.b - darkFill.b)
        XCTAssertGreaterThan(
            channelDelta, 0.3,
            "The fill cgColor must change between aqua and darkAqua (R14 — not frozen).")
    }
}
