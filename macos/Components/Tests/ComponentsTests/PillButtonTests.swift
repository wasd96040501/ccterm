import AppKit
import XCTest

@testable import Components

@MainActor
final class PillButtonTests: XCTestCase {
    /// The keys follow the title into dark mode: light ink on a dark pill, dark
    /// on a light one — never the light appearance's ink fixed when made.
    func testTheKeysFollowTheAppearance() throws {
        let button = PillButton(title: "Deny", keys: "⎋")
        let title = button.attributedTitle
        let keys = try XCTUnwrap(
            title.attribute(.foregroundColor, at: title.length - 1, effectiveRange: nil) as? NSColor)

        XCTAssertGreaterThan(try brightness(of: keys, in: .darkAqua), 0.5, "the keys are dark on a dark pill")
        XCTAssertLessThan(try brightness(of: keys, in: .aqua), 0.5, "the keys are light on a light pill")
    }

    private func brightness(of color: NSColor, in name: NSAppearance.Name) throws -> CGFloat {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var resolved: CGColor?
        appearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        let srgb = try XCTUnwrap(
            resolved.flatMap { NSColor(cgColor: $0) }?.usingColorSpace(.sRGB), "the colour has no sRGB form")
        return srgb.brightnessComponent
    }
}
