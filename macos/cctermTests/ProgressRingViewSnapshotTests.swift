import AppKit
import XCTest

@testable import ccterm

/// Review-only (opt-in, NOT a CI gate) snapshot of `ProgressRingView` —
/// the AppKit replacement for the SwiftUI `ProgressRingView`. Renders the
/// ring at the two consumer sizes ({12, 22}) across the three preview
/// percents ({30, 75, 95} — the same fractions as `ProgressRingView`'s
/// `#Preview` at `ProgressRingView.swift:36-43`) in BOTH light and dark
/// appearances, so the accent / orange / red band stepping, the -90° start
/// (arc grows from 12 o'clock), the round cap, and the gray track can be
/// eyeballed for parity against the SwiftUI original.
///
/// Run for the PNG:
///   make test-unit FILTER=ProgressRingViewSnapshotTests
///   open /tmp/ccterm-screenshots/ProgressRingView-light.png
///   open /tmp/ccterm-screenshots/ProgressRingView-dark.png
@MainActor
final class ProgressRingViewSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testProgressRingLight() throws {
        try render(appearanceName: .aqua, pngName: "ProgressRingView-light")
    }

    func testProgressRingDark() throws {
        try render(appearanceName: .darkAqua, pngName: "ProgressRingView-dark")
    }

    // MARK: - Harness

    private func render(appearanceName: NSAppearance.Name, pngName: String) throws {
        let percents: [Double] = [30, 75, 95]
        let sizes: [CGFloat] = [12, 22]

        let cellW: CGFloat = 80
        let cellH: CGFloat = 70
        let cols = percents.count
        let rows = sizes.count
        let canvas = CGSize(
            width: cellW * CGFloat(cols) + 24,
            height: cellH * CGFloat(rows) + 24)

        let root = NSView(frame: CGRect(origin: .zero, size: canvas))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.appearance = NSAppearance(named: appearanceName)

        for (rowIdx, size) in sizes.enumerated() {
            for (colIdx, percent) in percents.enumerated() {
                let ring = ProgressRingView(percent: percent, size: size)
                ring.translatesAutoresizingMaskIntoConstraints = true
                ring.autoresizingMask = []
                // Center the ring inside its cell.
                let cellX = 12 + CGFloat(colIdx) * cellW
                let cellY = 12 + CGFloat(rows - 1 - rowIdx) * cellH
                ring.frame = CGRect(
                    x: cellX + (cellW - size) / 2,
                    y: cellY + (cellH - size) / 2,
                    width: size,
                    height: size)
                root.addSubview(ring)
                ring.layoutSubtreeIfNeeded()
            }
        }

        let controller = NSViewController()
        controller.view = root

        let image = ViewSnapshot.renderViewController(controller, size: canvas)
        let url = ViewSnapshot.writePNG(image, name: pngName)

        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "\(pngName).png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertEqual(image.size.width, canvas.width, accuracy: 1)
    }
}
