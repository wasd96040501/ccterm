import AppKit
import XCTest

@testable import ccterm

/// Numbered lines mounted in a window, measured: how they scroll
/// (design/transcript/README.md "Scrollers") and what is text in them — the
/// lines, and not the gutter (02-command.md, 03-file.md).
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
        mount(.init(lines: Self.lines(200), style: .output))
        let scroll = try XCTUnwrap(stage?.find(NSScrollView.self), "premise: the lines scroll")
        let width = scroll.contentSize.width
        XCTAssertEqual(width, scroll.frame.width, "premise: no track beside the lines")

        scroll.scrollerStyle = .legacy
        stage?.drain()

        XCTAssertEqual(scroll.scrollerStyle, .overlay)
        XCTAssertTrue(scroll.autohidesScrollers, "the scroller shows only while scrolling")
        XCTAssertEqual(scroll.contentSize.width, width, "a legacy track took width from the lines")
    }

    /// Selecting lines paints the text, never the numbers beside it.
    func testASelectionNeverPaintsOverTheNumbers() throws {
        let view = mount(.init(lines: Self.lines(8), style: .output))
        let text = try XCTUnwrap(stage?.find(NSTextView.self))
        let textStart = try x(ofFirstCharacterIn: text, in: view)
        let gutter = NSRect(x: 0, y: 0, width: textStart, height: view.bounds.height)
        let lines = NSRect(x: textStart, y: 0, width: view.bounds.width - textStart, height: view.bounds.height)
        let (gutterBefore, linesBefore) = (pixels(of: view, in: gutter), pixels(of: view, in: lines))

        text.window?.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: 5, length: (text.string as NSString).length - 10))
        stage?.drain()

        XCTAssertNotEqual(pixels(of: view, in: lines), linesBefore, "premise: the selection shows")
        XCTAssertEqual(pixels(of: view, in: gutter), gutterBefore, "the selection painted over the numbers")
    }

    /// A press in the gutter reaches no text: the numbers are not text.
    func testAPressInTheGutterSelectsNothing() throws {
        let view = mount(.init(lines: Self.lines(8), style: .output))
        let text = try XCTUnwrap(stage?.find(NSTextView.self))
        let textStart = try x(ofFirstCharacterIn: text, in: view)
        let point = NSPoint(x: textStart / 2, y: view.bounds.height - 30)

        XCTAssertFalse(
            view.hitTest(point)?.isDescendant(of: text) ?? false, "the gutter's point is the text's")
        Self.doubleClick(in: view, at: point)
        stage?.drain()
        XCTAssertEqual(text.selectedRange().length, 0, "a press in the gutter selected text")
    }

    /// A file scrolled sideways keeps its numbers where they are: only the
    /// text moves under the gutter.
    func testTheNumbersStayWhenTheLinesScrollSideways() throws {
        let long = (1...30).map {
            NumberedLinesView.Line(number: $0, text: "let value\($0) = " + String(repeating: "x", count: 160))
        }
        let view = mount(.init(lines: long, style: .source), width: 360)
        let scroll = try XCTUnwrap(stage?.find(NSScrollView.self))
        let text = try XCTUnwrap(stage?.find(NSTextView.self))
        let textStart = try x(ofFirstCharacterIn: text, in: view)
        let gutter = NSRect(x: 0, y: 0, width: textStart, height: view.bounds.height)
        let before = pixels(of: view, in: gutter)

        scroll.contentView.scroll(to: NSPoint(x: 120, y: scroll.contentView.bounds.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        stage?.drain()

        XCTAssertEqual(scroll.contentView.bounds.minX, 120, "premise: the lines scrolled sideways")
        XCTAssertEqual(pixels(of: view, in: gutter), before, "the numbers moved with the text")
    }

    /// Scrolled down, the numbers stay inside the lines: the gutter is as
    /// tall as the file and floats outside the clip view, and must not draw
    /// over what stands above (an editor's tab bar).
    func testTheNumbersNeverDrawAboveTheLines() throws {
        let view = NumberedLinesView()
        view.configure(with: .init(lines: Self.lines(200), style: .source))
        let bar = NSView()
        let container = NSView()
        for subview in [bar, view] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: 40),
            view.topAnchor.constraint(equalTo: bar.bottomAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        let controller = NSViewController()
        controller.view = container
        let stage = AppKitStage.mount(controller, size: CGSize(width: 480, height: 300))
        self.stage = stage
        stage.drain()
        let scroll = try XCTUnwrap(stage.find(NSScrollView.self))
        let above = container.convert(bar.bounds, from: bar)
        let before = pixels(of: container, in: above)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
        scroll.reflectScrolledClipView(scroll.contentView)
        stage.drain()

        XCTAssertEqual(scroll.contentView.bounds.minY, 400, "premise: the lines scrolled down")
        XCTAssertEqual(pixels(of: container, in: above), before, "the numbers drew above the lines")
    }

    // MARK: - Helpers

    private static func lines(_ count: Int) -> [NumberedLinesView.Line] {
        (1...count).map { NumberedLinesView.Line(number: $0, text: "output line \($0) of the command") }
    }

    @discardableResult
    private func mount(_ content: NumberedLinesView.Content, width: CGFloat = 480) -> NumberedLinesView {
        let view = NumberedLinesView()
        view.configure(with: content)
        let controller = NSViewController()
        controller.view = view
        let stage = AppKitStage.mount(controller, size: CGSize(width: width, height: 300))
        self.stage = stage
        stage.drain()
        return view
    }

    /// Where the first line's text begins, in `view`'s coordinates.
    private func x(ofFirstCharacterIn text: NSTextView, in view: NSView) throws -> CGFloat {
        let window = try XCTUnwrap(text.window)
        let screen = text.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        return view.convert(window.convertFromScreen(screen), from: nil).minX
    }

    private func pixels(of view: NSView, in rect: NSRect) -> Data {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return Data() }
        view.cacheDisplay(in: rect, to: rep)
        return rep.tiffRepresentation ?? Data()
    }

    /// A double-click as a key window delivers one: to the view under the
    /// point. The stage's window is never key, and a press in a window that
    /// isn't only brings it forward, so the press goes to that view as the
    /// window would send it. The release is queued first: a press on text
    /// starts a tracking loop that ends on it.
    static func doubleClick(in view: NSView, at point: NSPoint) {
        guard let window = view.window, let content = window.contentView else { return }
        let location = view.convert(point, to: nil)
        guard let target = content.hitTest(content.superview?.convert(location, from: nil) ?? location) else { return }
        for count in 1...2 {
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count,
                    pressure: type == .leftMouseDown ? 1 : 0)
            }
            guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
            NSApp.postEvent(up, atStart: false)
            target.mouseDown(with: down)
        }
    }
}
