import XCTest

@testable import ccterm

/// Unit tests for the `CopyChrome` primitive — the value type shared by
/// `CodeBlockLayout`, `BashChildLayout`, and `DiffLayout` to host the
/// in-card "copy this" affordance.
///
/// Two things matter and only two:
///
/// 1. **`topRight` geometry** — hit rect is the shared 18pt square,
///    anchored at the container's top-right via the shared
///    `codeBlockChrome*` insets, with a width-narrowness guard. A drift
///    here would silently misalign the codeblock / bash / diff copy
///    chrome from the cell-margin gutter (whose glyph aligns to the
///    same chrome-row midpoint).
///
/// 2. **`derivedId` stability + uniqueness** — bash sub-cards (and any
///    future multi-card child) need a stable per-card id derived from
///    one `Child.id`. The post-click checkmark survives `make`
///    re-layouts only if the derivation is deterministic; sibling
///    flashes don't leak only if different slots → different UUIDs.
final class CopyChromeTests: XCTestCase {

    // MARK: - topRight geometry

    /// A normally-sized container should produce a chrome with:
    /// - hit rect = 18pt square (shared `gutterHitSize`)
    /// - right edge = container.maxX - codeBlockChromeRightInset
    /// - top edge  = container.minY + codeBlockChromeTopInset
    /// - center coincident with the hit rect's midpoint
    /// `id` and `text` pass through verbatim.
    func testTopRightAnchorsAtSharedInsetsAndCarriesPayload() {
        let id = UUID()
        let container = CGRect(x: 0, y: 0, width: 600, height: 200)
        let chrome = CopyChrome.topRight(of: container, id: id, text: "hello")

        XCTAssertNotNil(chrome, "wide container should produce a chrome")
        guard let c = chrome else { return }

        XCTAssertEqual(c.id, id)
        XCTAssertEqual(c.text, "hello")
        XCTAssertEqual(c.hitRect.width, BlockStyle.gutterHitSize)
        XCTAssertEqual(c.hitRect.height, BlockStyle.gutterHitSize)
        XCTAssertEqual(
            c.hitRect.maxX,
            container.maxX - BlockStyle.codeBlockChromeRightInset,
            accuracy: 0.001,
            "hit rect right edge must respect codeBlockChromeRightInset")
        XCTAssertEqual(
            c.hitRect.minY,
            container.minY + BlockStyle.codeBlockChromeTopInset,
            accuracy: 0.001,
            "hit rect top edge must respect codeBlockChromeTopInset")
        XCTAssertEqual(c.center.x, c.hitRect.midX, accuracy: 0.001)
        XCTAssertEqual(c.center.y, c.hitRect.midY, accuracy: 0.001)
    }

    /// Containers narrower than `hitSize + 2 * rightInset` cannot host
    /// the chrome past the inset and must return `nil`. Callers (today:
    /// codeblock + diff + bash) treat that as "no copy button on this
    /// row".
    func testTopRightReturnsNilForNarrowContainer() {
        let narrowWidth =
            BlockStyle.gutterHitSize + 2 * BlockStyle.codeBlockChromeRightInset - 1
        let container = CGRect(x: 0, y: 0, width: narrowWidth, height: 200)
        let chrome = CopyChrome.topRight(
            of: container, id: UUID(), text: "")
        XCTAssertNil(
            chrome,
            "pathologically narrow container must not produce a chrome")
    }

    /// Container offsets through to the produced rect — non-zero
    /// `(x, y)` of the container is reflected in the hit rect's anchor.
    /// Layouts position bash sub-cards at non-zero origins, so this
    /// case is the common one.
    func testTopRightHonorsContainerOrigin() {
        let container = CGRect(x: 40, y: 100, width: 400, height: 60)
        let chrome = CopyChrome.topRight(of: container, id: UUID(), text: "")
        XCTAssertNotNil(chrome)
        guard let c = chrome else { return }
        XCTAssertEqual(
            c.hitRect.maxX,
            container.maxX - BlockStyle.codeBlockChromeRightInset,
            accuracy: 0.001)
        XCTAssertEqual(
            c.hitRect.minY,
            container.minY + BlockStyle.codeBlockChromeTopInset,
            accuracy: 0.001)
    }

    // MARK: - derivedId

    /// Same `(base, slot)` pair must always return the same UUID. The
    /// post-click checkmark on `BlockCellView.copyFlashByActionId`
    /// keys on this id; instability would drop the flash mid-window
    /// every time `ToolGroupLayout.make` re-ran (hover transitions,
    /// width changes, token back-fill).
    func testDerivedIdIsDeterministic() {
        let base = UUID()
        let first = CopyChrome.derivedId(base: base, slot: 2)
        let second = CopyChrome.derivedId(base: base, slot: 2)
        XCTAssertEqual(first, second)
    }

    /// Different slots under the same `base` must produce different
    /// UUIDs. Bash sub-cards (command / stdout / stderr) share one
    /// `BashChild.id`; their per-card flash + hover state must not
    /// alias.
    func testDerivedIdDiffersBetweenSlots() {
        let base = UUID()
        let zero = CopyChrome.derivedId(base: base, slot: 0)
        let one = CopyChrome.derivedId(base: base, slot: 1)
        let two = CopyChrome.derivedId(base: base, slot: 2)
        XCTAssertNotEqual(zero, one)
        XCTAssertNotEqual(zero, two)
        XCTAssertNotEqual(one, two)
    }

    /// Different `base` UUIDs at the same slot produce different
    /// derived ids — i.e. the derivation is base-sensitive. (Slot-0
    /// trivially equals `base` under the XOR-with-zero recipe; that's
    /// fine because real bash children use distinct `child.id` values,
    /// and the diff bodies that consume `child.id` bare are siblings,
    /// not the same call site. The only real-world collision we worry
    /// about is within one base, across slots — covered above.)
    func testDerivedIdDistinguishesBetweenBases() {
        let a = UUID()
        let b = UUID()
        XCTAssertNotEqual(
            CopyChrome.derivedId(base: a, slot: 1),
            CopyChrome.derivedId(base: b, slot: 1),
            "derived ids must inherit `base`'s entropy")
    }
}
