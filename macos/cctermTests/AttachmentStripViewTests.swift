import AppKit
import XCTest

@testable import ccterm

/// CI-gate measurement test (non-snapshot → runs on the default suite) for
/// `AttachmentStripView` (migration plan §4.1, §9): the strip is a pure render
/// of an `[Attachment]`; it publishes `noIntrinsicMetric` (R1 — no
/// window-collapse leak) and a fixed 64pt height; cards measure 48×48 (image) /
/// height 48 (file). Drives the REAL `reconcile(_:)` and asserts on the
/// produced card subviews.
@MainActor
final class AttachmentStripViewTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func mounted(_ strip: AttachmentStripView, width: CGFloat = 400) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 80))
        strip.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            strip.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        return container
    }

    private func imageAttachment() -> Attachment {
        Attachment(
            kind: .image(data: Data([0x1]), mediaType: "image/png"),
            thumbnail: NSImage(size: NSSize(width: 12, height: 12)),
            filename: "shot.png")
    }

    private func fileAttachment(path: String = "/tmp/notes.txt") -> Attachment {
        Attachment(
            kind: .file(path: path),
            thumbnail: NSImage(size: NSSize(width: 12, height: 12)),
            filename: (path as NSString).lastPathComponent)
    }

    // MARK: - noIntrinsicMetric (R1)

    func testStripPublishesNoIntrinsicMetric() {
        let strip = AttachmentStripView()
        XCTAssertEqual(
            strip.intrinsicContentSize.width, NSView.noIntrinsicMetric,
            "Strip width must be noIntrinsicMetric so it can't leak fittingSize.width up (R1).")
        XCTAssertEqual(
            strip.intrinsicContentSize.height, NSView.noIntrinsicMetric,
            "Strip height must be noIntrinsicMetric — its band height is a @required constraint.")
    }

    // MARK: - Fixed 64pt band height

    func testStripFixedHeightIs64() {
        let strip = AttachmentStripView()
        let container = mounted(strip)
        strip.reconcile([imageAttachment(), fileAttachment()])
        container.layoutSubtreeIfNeeded()
        // thumbnailSize(48) + top(8) + bottom(8) = 64.
        XCTAssertEqual(AttachmentStripView.stripHeight, 64, accuracy: 0.5)
        XCTAssertEqual(
            strip.frame.height, 64, accuracy: 0.5,
            "The strip's @required height constraint pins the band at 64pt.")
    }

    // MARK: - One card per attachment + card geometry

    func testReconcileRendersOneCardPerAttachmentWithExpectedSizes() {
        let strip = AttachmentStripView()
        let container = mounted(strip)
        strip.reconcile([imageAttachment(), fileAttachment()])
        container.layoutSubtreeIfNeeded()

        XCTAssertEqual(strip.cardViews.count, 2, "Two attachments → two cards.")

        // Both cards are 48pt tall (image is 48×48, file row is height 48).
        for card in strip.cardViews {
            XCTAssertEqual(
                card.frame.height, AttachmentCardView.thumbnailSize, accuracy: 1,
                "Every card is 48pt tall.")
        }
        // The image card is square 48×48.
        let imageCard = strip.cardViews[0]
        XCTAssertEqual(
            imageCard.frame.width, AttachmentCardView.thumbnailSize, accuracy: 1,
            "An image card is a 48×48 square.")
    }

    // MARK: - Remove shrinks the strip

    func testReconcileShrinksOnRemoval() {
        let strip = AttachmentStripView()
        let container = mounted(strip)
        let img = imageAttachment()
        let file = fileAttachment()
        strip.reconcile([img, file])
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(strip.cardViews.count, 2)

        // Reconcile with one removed (the array is the source of truth).
        strip.reconcile([file])
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(strip.cardViews.count, 1, "Reconcile with one attachment leaves one card.")
    }

    // MARK: - Callbacks wired per card

    func testRemoveCallbackCarriesAttachmentId() {
        let strip = AttachmentStripView()
        _ = mounted(strip)
        let file = fileAttachment()
        var removed: UUID?
        strip.onRemove = { removed = $0 }
        strip.reconcile([file])

        // Drive the card's remove path by invoking the wired closure the way the
        // chip's click would (the strip wires `card.onRemove` to forward the id).
        strip.cardViews.first?.onRemove?()
        XCTAssertEqual(removed, file.id, "Remove forwards the card's attachment id.")
    }

    func testImageTapCallbackOnlyOnImageCards() {
        let strip = AttachmentStripView()
        _ = mounted(strip)
        var tapped = 0
        strip.onImageTapped = { _ in tapped += 1 }
        strip.reconcile([imageAttachment(), fileAttachment()])

        // The image card has an onTapped closure; the file card does not.
        XCTAssertNotNil(strip.cardViews[0].onTapped, "Image card is tappable.")
        XCTAssertNil(strip.cardViews[1].onTapped, "File card has no preview tap.")
        strip.cardViews[0].onTapped?()
        XCTAssertEqual(tapped, 1, "Tapping the image card routes one preview request.")
    }

    // MARK: - AttachmentCardView real hit-test paths (drive mouseDown/mouseUp)

    /// Mount a single card in an offscreen window so window→view coordinate
    /// conversion is real for the card's `content.frame.contains(p)` /
    /// `RemoveChipButton.bounds.contains(p)` guards.
    private func windowedCard(_ card: AttachmentCardView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 120, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 120))
        window.contentView = container
        window.ccterm_orderFrontForTesting()
        card.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            card.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            card.widthAnchor.constraint(equalToConstant: AttachmentCardView.thumbnailSize),
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

    /// (1) A mouse-up INSIDE the image card's 48×48 content fires `onTapped`.
    func testImageCardMouseUpInsideContentFiresOnTapped() {
        let card = AttachmentCardView(attachment: imageAttachment())
        var tapped = 0
        card.onTapped = { tapped += 1 }
        let window = windowedCard(card)
        defer {
            window.contentView = nil
            window.close()
        }

        // Center of the card → inside content (content fills the card's bounds).
        let centerInWindow = card.convert(
            NSPoint(x: card.bounds.midX, y: card.bounds.midY), to: nil)
        card.mouseDown(with: mouseEvent(.leftMouseDown, at: centerInWindow, in: window))
        card.mouseUp(with: mouseEvent(.leftMouseUp, at: centerInWindow, in: window))
        XCTAssertEqual(tapped, 1, "A mouse-up inside the 48×48 content opens the preview once.")
    }

    /// (2) A mouse-up OUTSIDE the content (far from the card) must NOT fire
    /// `onTapped` — the production guard is `content.frame.contains(p)`.
    func testImageCardMouseUpOutsideContentDoesNotFireOnTapped() {
        let card = AttachmentCardView(attachment: imageAttachment())
        var tapped = 0
        card.onTapped = { tapped += 1 }
        let window = windowedCard(card)
        defer {
            window.contentView = nil
            window.close()
        }

        let centerInWindow = card.convert(
            NSPoint(x: card.bounds.midX, y: card.bounds.midY), to: nil)
        card.mouseDown(with: mouseEvent(.leftMouseDown, at: centerInWindow, in: window))
        // Release far outside the card's bounds.
        let outside = NSPoint(x: centerInWindow.x + 500, y: centerInWindow.y + 500)
        card.mouseUp(with: mouseEvent(.leftMouseUp, at: outside, in: window))
        XCTAssertEqual(tapped, 0, "A mouse-up outside the content must NOT open the preview.")
    }

    /// (3) A click on the top-trailing remove chip fires `onRemove` and does NOT
    /// fire the card's `onTapped`. Routed through the real `hitTest` so the
    /// production `RemoveChipButton.bounds.contains(p)` guard runs.
    func testRemoveChipClickFiresOnRemoveNotOnTapped() throws {
        let card = AttachmentCardView(attachment: imageAttachment())
        var tapped = 0
        var removed = 0
        card.onTapped = { tapped += 1 }
        card.onRemove = { removed += 1 }
        let window = windowedCard(card)
        defer {
            window.contentView = nil
            window.close()
        }
        let container = try XCTUnwrap(window.contentView)

        // The remove chip is the card's `NSControl` subview (the content
        // container is a plain NSView). Locate it by type so the test targets
        // the chip's real frame rather than guessing its glyph geometry.
        let chip = try XCTUnwrap(
            card.subviews.first { $0 is NSControl },
            "The card must mount its remove-chip NSControl subview.")
        // `chip.frame` is already in the card's coordinate space.
        let chipCenterInCard = NSPoint(x: chip.frame.midX, y: chip.frame.midY)
        let chipPointInContainer = card.convert(chipCenterInCard, to: container)
        let hit = try XCTUnwrap(
            container.hitTest(chipPointInContainer),
            "A point over the chip must hit-test to a real view.")
        XCTAssertFalse(
            hit === card,
            "The chip center hit-tests to the remove chip subtree, not the card itself.")
        XCTAssertTrue(
            hit === chip || hit.isDescendant(of: chip),
            "The chip center hit-tests into the remove chip subtree.")

        // AppKit routes the event to the chip control (its NSImageView child has
        // no mouseUp override). Drive the chip's REAL `mouseUp` guard
        // (`bounds.contains(p)`) at the chip's own center.
        let chipCenterInWindow = chip.convert(
            NSPoint(x: chip.bounds.midX, y: chip.bounds.midY), to: nil)
        chip.mouseDown(with: mouseEvent(.leftMouseDown, at: chipCenterInWindow, in: window))
        chip.mouseUp(with: mouseEvent(.leftMouseUp, at: chipCenterInWindow, in: window))
        XCTAssertEqual(removed, 1, "Clicking the remove chip fires onRemove once.")
        XCTAssertEqual(tapped, 0, "Clicking the remove chip must NOT also open the preview.")
    }
}
