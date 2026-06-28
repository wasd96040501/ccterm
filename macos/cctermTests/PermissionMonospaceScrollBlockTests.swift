import AppKit
import XCTest

@testable import ccterm

/// CI-gate measurement test (non-snapshot) for `PermissionMonospaceScrollBlock`
/// (migration plan §4.4-7, §9). Reproduces `BoundedHeightScrollView`'s
/// `min(content.idealHeight, maxHeight)`: intrinsic when the text fits, capped +
/// scrolling when it overflows. Drives the real production object — mounts at a
/// fixed settled width, lays out, and reads the resolved height — never a
/// re-implemented approximation.
@MainActor
final class PermissionMonospaceScrollBlockTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Mount the block at a fixed width in an offscreen window so the text
    /// view's content width settles (the used-height is meaningless before
    /// the wrap width is real).
    private func mounted(
        _ block: PermissionMonospaceScrollBlock, width: CGFloat = 400
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        window.contentView = container
        window.ccterm_orderFrontForTesting()
        block.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(block)
        NSLayoutConstraint.activate([
            block.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            block.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            block.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        return window
    }

    // MARK: - Short text → intrinsic height (below cap)

    /// The size-12 monospaced line height, computed INDEPENDENTLY of the
    /// production block (via the same font the block uses, but through a fresh
    /// layout manager) — so the below-cap assertions compare against a value the
    /// production measurement path did not produce.
    private func monospacedLineHeight() -> CGFloat {
        let font = NSFont.monospacedSystemFont(
            ofSize: PermissionMonospaceScrollBlock.textFontSize, weight: .regular)
        return NSLayoutManager().defaultLineHeight(for: font)
    }

    func testShortTextSizesToUsedHeightBelowCap() {
        let block = PermissionMonospaceScrollBlock(text: "one line", maxHeight: 200)
        let window = mounted(block)
        defer {
            window.contentView = nil
            window.close()
        }
        block.layoutSubtreeIfNeeded()

        let used = block.usedTextHeight
        XCTAssertGreaterThan(used, 0, "A single line typesets a positive used height.")
        XCTAssertLessThan(used, 200, "A single line is well below the 200pt cap.")

        // Independent check: a single un-wrapped line resolves to one
        // monospaced line height (within a half-line tolerance for ascender /
        // leading rounding) — NOT just `min(used, cap)`, which would be
        // tautological against the production measurement.
        let oneLine = monospacedLineHeight()
        XCTAssertEqual(
            block.resolvedHeight, oneLine, accuracy: oneLine * 0.5 + 1,
            "Below the cap, a single line resolves to ~one monospaced line height.")
        XCTAssertLessThan(
            block.resolvedHeight, oneLine * 2,
            "A single short line never resolves to two-or-more line heights.")
    }

    func testMultiLineBelowCapResolvesToLineCountHeight() {
        // Five short, non-wrapping lines at a wide width → ~5 line heights,
        // checked against an INDEPENDENT line-height × count, not the production
        // measurement function.
        let block = PermissionMonospaceScrollBlock(
            text: (0..<5).map { "line \($0)" }.joined(separator: "\n"), maxHeight: 200)
        let window = mounted(block, width: 500)
        defer {
            window.contentView = nil
            window.close()
        }
        block.layoutSubtreeIfNeeded()
        let oneLine = monospacedLineHeight()
        XCTAssertEqual(
            block.resolvedHeight, oneLine * 5, accuracy: oneLine,
            "Five non-wrapping lines resolve to ~5 monospaced line heights (independent measure).")
        XCTAssertLessThan(block.resolvedHeight, 200, "Five lines are below the 200pt cap.")
    }

    func testDoesNotStretchToFillTallParent() {
        // A short block must NOT stretch to fill a parent that offers MUCH more
        // vertical space than min(used, cap). Pin the block's bottom to a tall
        // container so a stretch would show up as a too-tall frame.
        let block = PermissionMonospaceScrollBlock(text: "one line", maxHeight: 200)
        let width: CGFloat = 400
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        window.contentView = container
        window.ccterm_orderFrontForTesting()
        block.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(block)
        // Pin top/leading/trailing AND keep the bottom ≥ the block bottom with a
        // low priority so the container offers slack but does not force a
        // stretch — the high-priority height clamp must win.
        let slack = block.bottomAnchor.constraint(
            lessThanOrEqualTo: container.bottomAnchor)
        NSLayoutConstraint.activate([
            block.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            block.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            block.topAnchor.constraint(equalTo: container.topAnchor),
            slack,
        ])
        container.layoutSubtreeIfNeeded()
        block.layoutSubtreeIfNeeded()
        defer {
            window.contentView = nil
            window.close()
        }
        let used = block.usedTextHeight
        XCTAssertEqual(
            block.frame.height, min(used, 200), accuracy: 1.0,
            "Offered 600pt of vertical slack, the block stays at min(used, cap), not stretched.")
        XCTAssertLessThan(
            block.frame.height, 100,
            "A single-line block does not balloon to fill the tall parent.")
    }

    // MARK: - Long text → caps at the parameter

    func testLongTextCapsAt200() {
        let lines = (0..<120).map { "line \($0) of a very long monospaced block" }
            .joined(separator: "\n")
        let block = PermissionMonospaceScrollBlock(text: lines, maxHeight: 200)
        let window = mounted(block)
        defer {
            window.contentView = nil
            window.close()
        }
        block.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(
            block.usedTextHeight, 200,
            "120 lines typeset well past the cap (so the clamp is load-bearing).")
        XCTAssertEqual(
            block.resolvedHeight, 200, accuracy: 0.5,
            "Overflowing text clamps to exactly the 200pt cap.")
    }

    func testLongTextCapsAt480WhenThatCapIsPassed() {
        let lines = (0..<200).map { "line \($0)" }.joined(separator: "\n")
        let block = PermissionMonospaceScrollBlock(text: lines, maxHeight: 480)
        let window = mounted(block)
        defer {
            window.contentView = nil
            window.close()
        }
        block.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(block.usedTextHeight, 480, "200 lines exceed the 480pt cap.")
        XCTAssertEqual(
            block.resolvedHeight, 480, accuracy: 0.5,
            "The cap is threaded — a 480 caller clamps at 480, not 200.")
    }

    // MARK: - Read-only + selectable (no IME; ⌘C works)

    func testTextViewIsNonEditableAndSelectable() {
        let block = PermissionMonospaceScrollBlock(text: "x", maxHeight: 200)
        let window = mounted(block)
        defer {
            window.contentView = nil
            window.close()
        }
        XCTAssertFalse(
            block.isTextEditable,
            "isEditable == false → no IME marked-text machinery.")
        XCTAssertTrue(
            block.isTextSelectable,
            "isSelectable == true → drag-select + ⌘C work.")
    }
}
