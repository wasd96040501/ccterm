import AppKit
import XCTest

@testable import ccterm

/// Numbered lines mounted in a window, measured: how they scroll
/// (design/transcript/README.md "Scrollers").
@MainActor
final class NumberedLinesViewTests: XCTestCase {
    private var stage: AppKitStage?

    override func tearDown() {
        stage?.teardown()
        stage = nil
        super.tearDown()
    }

    /// The scroller floats over the lines whatever the system setting: when
    /// AppKit hands the scroll view the legacy style (as it does to every
    /// scroll view when *Show scroll bars* changes), it stays overlay and the
    /// lines keep the whole width.
    func testTheScrollerFloatsOverTheLinesWhateverTheSetting() throws {
        let view = NumberedLinesView()
        let lines = (1...200).map { NumberedLinesView.Line(number: $0, text: "line \($0)") }
        view.configure(with: .init(lines: lines, style: .output))
        let controller = NSViewController()
        controller.view = view
        let stage = AppKitStage.mount(controller, size: CGSize(width: 480, height: 300))
        self.stage = stage
        stage.drain()
        let scroll = try XCTUnwrap(stage.find(NSScrollView.self), "premise: the lines scroll")
        let width = scroll.contentSize.width
        XCTAssertEqual(width, scroll.frame.width, "premise: no track beside the lines")

        scroll.scrollerStyle = .legacy
        stage.drain()

        XCTAssertEqual(scroll.scrollerStyle, .overlay)
        XCTAssertTrue(scroll.autohidesScrollers, "the scroller shows only while scrolling")
        XCTAssertEqual(scroll.contentSize.width, width, "a legacy track took width from the lines")
    }
}
