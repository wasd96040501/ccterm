import AppKit
import XCTest

@testable import ccterm

/// Review-only (opt-in, NOT a CI gate) snapshot of `GlassBackgroundView` in the
/// three consumer geometries — input pill (r16), chrome button (r8), attach
/// circle (r16) — rendered in BOTH light and dark appearances. Used to
/// settle D3 (the macOS 14/15 `NSVisualEffectView.Material` choice) and to
/// confirm the material + the content clip + the shadow-outside-clip + the
/// separator stroke all read correctly.
///
/// Run for the PNG:
///   make test-unit FILTER=GlassBackgroundViewSnapshotTests
///   open /tmp/ccterm-screenshots/GlassBackground-light.png
///   open /tmp/ccterm-screenshots/GlassBackground-dark.png
@MainActor
final class GlassBackgroundViewSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testBarSurfaceLight() throws {
        try render(appearanceName: .aqua, pngName: "GlassBackground-light")
    }

    func testBarSurfaceDark() throws {
        try render(appearanceName: .darkAqua, pngName: "GlassBackground-dark")
    }

    // MARK: - Harness

    private func render(appearanceName: NSAppearance.Name, pngName: String) throws {
        let size = CGSize(width: 420, height: 260)

        // A backdrop so vibrancy / shadow read against something.
        let root = NSView(frame: CGRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.appearance = NSAppearance(named: appearanceName)

        // Input pill (r16) with a label inside (proves the content clip).
        let pill = makeSurface(cornerRadius: 16, label: "Send a message")
        place(pill, in: root, frame: CGRect(x: 24, y: 180, width: 372, height: 48))

        // Chrome button (r8).
        let chrome = makeSurface(cornerRadius: 8, label: "Auto")
        place(chrome, in: root, frame: CGRect(x: 24, y: 120, width: 80, height: 22))

        // Attach circle (r16 = size/2 for a 32pt button). The attach button
        // is shadowless (drawsShadow:false) — matching AttachButton.surface.
        let attach = makeSurface(cornerRadius: 16, label: "+", drawsShadow: false)
        place(attach, in: root, frame: CGRect(x: 120, y: 115, width: 32, height: 32))

        let controller = NSViewController()
        controller.view = root

        let image = ViewSnapshot.renderViewController(controller, size: size)
        let url = ViewSnapshot.writePNG(image, name: pngName)

        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "\(pngName).png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertEqual(image.size.width, size.width, accuracy: 1)
    }

    private func makeSurface(
        cornerRadius: CGFloat, label: String, drawsShadow: Bool = true
    )
        -> GlassBackgroundView
    {
        let surface = GlassBackgroundView(cornerRadius: cornerRadius, drawsShadow: drawsShadow)
        let field = NSTextField(labelWithString: label)
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.alignment = .center
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(field)
        NSLayoutConstraint.activate([
            field.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            field.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        surface.setContentView(host)
        return surface
    }

    private func place(_ surface: GlassBackgroundView, in root: NSView, frame: CGRect) {
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.autoresizingMask = []
        root.addSubview(surface)
        surface.frame = frame
        surface.layoutSubtreeIfNeeded()
    }
}
