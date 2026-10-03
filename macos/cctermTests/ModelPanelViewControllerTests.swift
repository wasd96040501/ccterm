import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// The model panel's sticky account header (design 08 *Model*: each account's
/// header sticks to the top as its models pass under it), on the real panel
/// scrolled off screen.
@MainActor
final class ModelPanelViewControllerTests: XCTestCase {
    private typealias F = ComposerFixtures

    private var window: NSWindow!
    private var panel: ModelPanelViewController!

    override func setUp() async throws {
        continueAfterFailure = false
        panel = ModelPanelViewController()
        panel.configure(with: F.model(.draft, settings: F.settings("opus")))
        window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: ModelPanelViewController.width, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = panel
        panel.view.layoutSubtreeIfNeeded()
    }

    override func tearDown() async throws {
        window.close()
    }

    private var scrollView: NSScrollView {
        get throws { try XCTUnwrap(panel.view.subviews.compactMap { $0 as? NSScrollView }.first) }
    }

    private var table: NSTableView {
        get throws { try XCTUnwrap(try scrollView.documentView as? NSTableView) }
    }

    /// The header laid over the list — the panel's own subview, not a row.
    private var sticky: NSView {
        get throws {
            try XCTUnwrap(
                panel.view.subviews.first { String(describing: type(of: $0)) == "PanelHeaderCell" },
                "no sticky header over the list")
        }
    }

    private func words(in view: NSView) -> [String] {
        (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(words(in:))
    }

    private func scroll(to y: CGFloat) throws {
        let scrollView = try scrollView
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func headerRows() -> [Int] {
        panel.rows.indices.filter { if case .header = panel.rows[$0] { true } else { false } }
    }

    func testAtTheTopTheFirstHeaderIsItsOwnRow() throws {
        try scroll(to: 0)
        XCTAssertTrue(try sticky.isHidden, "a header over the list's own first header")
    }

    func testTheHeaderOfTheSectionUnderTheTopSticks() throws {
        try scroll(to: 100)

        let sticky = try sticky
        XCTAssertFalse(sticky.isHidden)
        XCTAssertEqual(sticky.frame.maxY, try scrollView.frame.maxY, accuracy: 0.5, "not at the list's top")
        XCTAssertTrue(words(in: sticky).contains("Claude Max"), "\(words(in: sticky))")
    }

    func testTheNextHeaderPushesItUpThenTakesItsPlace() throws {
        let relay = try table.rect(ofRow: headerRows()[1])
        let height = try table.rect(ofRow: headerRows()[0]).height

        try scroll(to: relay.minY - 10)
        XCTAssertEqual(
            try sticky.frame.maxY, try scrollView.frame.maxY + height - 10, accuracy: 0.5, "not pushed by the next")
        XCTAssertTrue(words(in: try sticky).contains("Claude Max"))

        try scroll(to: relay.minY + 5)
        let next = try sticky
        XCTAssertEqual(next.frame.maxY, try scrollView.frame.maxY, accuracy: 0.5)
        XCTAssertTrue(words(in: next).contains("Work Relay"), "\(words(in: next))")
    }
}
