import AppKit
import XCTest

@testable import Components
@testable import ComponentsDesign

/// The composer's card in the two places the app puts it, at the widths it
/// is given: as wide as its place allows — the New view's 640 slot, the
/// session's 720 column — and narrower only when the place is. A wish under
/// a split's holding must still beat everything inside the card.
@MainActor
final class ComposerWidthTests: XCTestCase {
    private var window: NSWindow!

    override func setUp() {
        window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 900, height: 720), styleMask: [.borderless],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
    }

    override func tearDown() {
        window.close()
    }

    /// Mounted as the session tab mounts a draft: the composer pinned to the
    /// New view's slot, the slot as tall as the composer.
    func testInTheNewViewTheCardFillsTheSlot() throws {
        for state in [ComposerFixtures.newTab, ComposerFixtures.idle] {
            let page = NewSessionViewController()
            let composer = ComposerViewController()
            composer.configure(with: state)
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 720))
            window.contentView = root
            page.view.frame = root.bounds
            page.view.autoresizingMask = [.width, .height]
            root.addSubview(page.view)
            page.configure(with: NewSessionSpecimen.State.rest.content)
            composer.view.translatesAutoresizingMaskIntoConstraints = false
            page.view.addSubview(composer.view)
            let guide = page.composerGuide
            NSLayoutConstraint.activate([
                composer.view.topAnchor.constraint(equalTo: guide.topAnchor),
                composer.view.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                composer.view.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
                guide.heightAnchor.constraint(equalTo: composer.view.heightAnchor),
            ])
            root.layoutSubtreeIfNeeded()
            root.layoutSubtreeIfNeeded()
            let card = try XCTUnwrap(composer.view.subviews.first { $0 is ComposerView } as? ComposerView)
            XCTAssertEqual(guide.frame.width, 640, "the slot")
            XCTAssertEqual(card.cardFrame.width, 640, accuracy: 0.5, "the card fills the slot")
        }
    }

    /// Mounted as a session's tab mounts it: 720 wished for, never wider than
    /// the tab less 16 a side.
    func testInASessionTheCardIsTheColumn() throws {
        for (width, expected) in [(CGFloat(900), CGFloat(720)), (600, 568)] {
            let composer = ComposerViewController()
            composer.configure(with: ComposerFixtures.idle)
            window.setContentSize(NSSize(width: width, height: 720))
            let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 720))
            window.contentView = root
            composer.view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(composer.view)
            let wish = composer.view.widthAnchor.constraint(equalToConstant: 720)
            wish.priority = .wish
            NSLayoutConstraint.activate([
                composer.view.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
                composer.view.centerXAnchor.constraint(equalTo: root.centerXAnchor),
                composer.view.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
                composer.view.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -32),
                wish,
            ])
            root.layoutSubtreeIfNeeded()
            root.layoutSubtreeIfNeeded()
            let card = try XCTUnwrap(composer.view.subviews.first { $0 is ComposerView } as? ComposerView)
            XCTAssertEqual(card.cardFrame.width, expected, accuracy: 0.5, "in a tab \(width) wide")
        }
    }
}
