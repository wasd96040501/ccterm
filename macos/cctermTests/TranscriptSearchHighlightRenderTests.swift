import AppKit
import XCTest

@testable import ccterm

/// Render-level regression gate for in-transcript search highlighting on
/// tool-group bodies. A `toolGroup` row paints its expanded body in a
/// layer-backed subview that composites OVER the cell bitmap, so a
/// highlight drawn at the cell level (where `BlockCellView.draw` paints
/// the yellow rects) is hidden — the highlight has to be routed through
/// the subview plan like selection is. This test caught that the search
/// path skipped `syncSubviewPlan`, so tool bodies never highlighted.
///
/// Not a `*SnapshotTests` file — it asserts on sampled pixels and runs on
/// the default suite / CI as a merge gate. The PNG is attached for human
/// debugging, but the pass/fail is the pixel count.
///
/// The fixture puts the query term ONLY in the tool body (the paragraph
/// has none), so any warm highlight pixels in the frame must come from
/// the tool body. Pre-fix that count is zero; post-fix it's a band.
@MainActor
final class TranscriptSearchHighlightRenderTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testToolBodySearchHitPaintsHighlight() {
        let groupId = UUID()
        let bashId = UUID()
        let controller = Transcript2Controller()
        controller.apply(
            .append([
                // Paragraph deliberately has NO occurrence of the query.
                Block(id: UUID(), kind: .paragraph(inlines: [.text("the quick brown fox")])),
                Block(
                    id: groupId,
                    kind: .toolGroup(
                        ToolGroupBlock(
                            activeTitle: "Running command",
                            expandedActiveTitle: "Running 1 command",
                            completedTitle: "Ran 1 command",
                            children: [
                                .bash(
                                    BashChild(
                                        id: bashId,
                                        label: "Ran 'ls'",
                                        activeLabel: "Running 'ls'",
                                        command: "ls",
                                        stdout: "apple banana cherry",
                                        stderr: nil))
                            ]))),
            ]))
        let mounted = MountedTranscript.mount(controller: controller)
        defer { mounted.teardown() }

        controller.coordinator.toggleFold(id: groupId)
        controller.coordinator.toggleFold(id: bashId)
        controller.runSearch("apple")
        XCTAssertEqual(
            controller.coordinator.search.totalHits, 1,
            "only the tool body contains the query")

        mounted.drain(seconds: 0.3)

        let scroll = mounted.scroll
        guard let rep = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds) else {
            return XCTFail("bitmapImageRepForCachingDisplay returned nil")
        }
        scroll.cacheDisplay(in: scroll.bounds, to: rep)

        // Attach the PNG for human debugging (pass/fail is the count).
        let image = NSImage(size: scroll.bounds.size)
        image.addRepresentation(rep)
        let url = ViewSnapshot.writePNG(image, name: "SearchHighlightTool")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "SearchHighlightTool.png"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Count "warm highlight" pixels: the search fill is systemYellow /
        // systemOrange over a dark card → R high, B low. Plain card text
        // (light grey, B high) and the dark backplate (all low) are
        // excluded. The paragraph carries no hit, so a positive count can
        // only be the tool body's highlight band.
        // `bitmapImageRepForCachingDisplay`'s rep is not reliably
        // sampleable via `colorAt` (its backing format returns nil), so
        // re-decode the PNG we just wrote into a standard 8-bit RGBA rep.
        guard let pngData = try? Data(contentsOf: url),
            let sampled = NSBitmapImageRep(data: pngData)
        else { return XCTFail("could not decode captured PNG for sampling") }
        let w = sampled.pixelsWide
        let h = sampled.pixelsHigh
        var warm = 0
        for y in stride(from: 0, to: h, by: 4) {
            for x in stride(from: 0, to: w, by: 4) {
                guard let c = sampled.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                let r = c.redComponent * 255
                let g = c.greenComponent * 255
                let b = c.blueComponent * 255
                // The search fill over the dark card samples ≈
                // (158, 123, 78): red clearly leads blue. Light card text
                // (≈ equal, all high) and the dark backplate (all low)
                // both fail `r − b > 40`.
                if r > 120, (r - b) > 40, g > b {
                    warm += 1
                }
            }
        }
        XCTAssertGreaterThan(
            warm, 5,
            "expanded tool body's search hit must paint a visible highlight "
                + "band (got \(warm) warm pixels — 0 means the highlight is "
                + "hidden under the body subview again)")
    }
}
