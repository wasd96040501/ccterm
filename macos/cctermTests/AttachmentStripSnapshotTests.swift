import AppKit
import XCTest

@testable import ccterm

/// Review-only snapshots (`*SnapshotTests` suffix → SKIPPED on the default
/// suite / CI). Renders the attachment surfaces for visual parity eyeballing —
/// NOT a regression gate. PNGs land under `/tmp/ccterm-screenshots/`.
@MainActor
final class AttachmentStripSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// A small solid-color NSImage thumbnail.
    private func swatch(_ color: NSColor, size: CGFloat = 48) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        return image
    }

    // MARK: - Strip: image + file card

    func testStripImageAndFileCards() throws {
        let strip = AttachmentStripView()
        strip.reconcile([
            Attachment(
                kind: .image(data: Data([0x1]), mediaType: "image/png"),
                thumbnail: swatch(.systemTeal), filename: "screenshot.png"),
            Attachment(
                kind: .file(path: "/tmp/Sources/Greeter.swift"),
                thumbnail: NSWorkspace.shared.icon(forFile: "/etc/hosts"),
                filename: "Greeter.swift"),
        ])

        let host = NSViewController()
        host.view = wrap(strip, width: 360, height: 64)
        let image = ViewSnapshot.renderViewController(
            host, size: CGSize(width: 360, height: 64), settle: 0.4)
        attach(image, name: "AttachmentStrip")
        XCTAssertGreaterThanOrEqual(image.size.width, 300)
    }

    // MARK: - Attach button idle vs drop-targeted

    func testAttachButtonIdleVsDropTargeted() throws {
        let idle = AttachButtonView()
        let targeted = AttachButtonView()
        targeted.setDropTargeted(true, in: NSAnimationContext.current)

        let row = NSStackView(views: [idle, targeted])
        row.orientation = .horizontal
        row.spacing = 24
        row.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let host = NSViewController()
        host.view = wrap(row, width: 120, height: 64)
        let image = ViewSnapshot.renderViewController(
            host, size: CGSize(width: 120, height: 64), settle: 0.4)
        attach(image, name: "AttachButtonIdleVsTargeted")
        XCTAssertGreaterThanOrEqual(image.size.width, 100)
    }

    // MARK: - Image preview sheet VC

    func testImagePreviewSheet() throws {
        let vc = ImagePreviewSheetViewController(
            image: swatch(.systemIndigo, size: 200), envelope: .inputBar,
            imagePadding: 20, onDismiss: {})
        let image = ViewSnapshot.renderViewController(
            vc, size: CGSize(width: 520, height: 420), settle: 0.4)
        attach(image, name: "ImagePreviewSheet")
        XCTAssertGreaterThanOrEqual(image.size.width, 500)
    }

    // MARK: - Helpers

    private func wrap(_ view: NSView, width: CGFloat, height: CGFloat) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func attach(_ image: NSImage, name: String) {
        let url = ViewSnapshot.writePNG(image, name: name)
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
