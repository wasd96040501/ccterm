import DisplayModels
import XCTest

@testable import Components
@testable import ComponentsDesign

/// The thumbnails' arithmetic: the same one the view lays out with.
@MainActor
final class AttachmentsRowViewTests: XCTestCase {
    func testTheThumbnailsLayoutWrapsWithinTheBubblesShareAndRightAligns() {
        let wide = RowsSpecimen.image(number: 1, width: 400, height: 200)
        let frames = AttachmentsRowView.frames(for: [wide, wide, wide], width: 520)
        // 192 wide each, 4 apart: two fit in 75 % of 520 (390), the third wraps.
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames[0].height, 96)
        XCTAssertEqual(frames[0].width, 192)
        XCTAssertEqual(frames[1].maxX, 520, "right-aligned with the bubble")
        XCTAssertEqual(frames[1].minX - frames[0].maxX, 4)
        XCTAssertEqual(frames[2].minY, 100, "wrapped under the first, 4 apart")
        XCTAssertEqual(frames[2].maxX, 520)
        XCTAssertEqual(
            AttachmentsRowView.height(
                for: .init(images: [wide, wide, wide], titles: [], highlighted: nil), width: 520), 196)
    }

    private final class Spy: PageRowViewDelegate {
        var opened: [String] = []
        func pageRowView(_ rowView: NSView, didRequestDocument id: String, pinned: Bool) { opened.append(id) }
        func pageRowView(_ rowView: NSView, didToggleDisclosureOf runID: String, inAllRuns all: Bool) {}
        func pageRowView(_ rowView: NSView, didRequestAllItemsOf runID: String) {}
        func pageRowView(_ rowView: NSView, didRequestOriginOf callID: String) {}
        func pageRowView(_ rowView: NSView, didDecide decision: Decision, forCall callID: String) {}
    }

    /// VoiceOver finds each thumbnail as an image named by its title, and
    /// pressing it opens it.
    func testEachThumbnailIsAnImageVoiceOverCanOpen() throws {
        let image = RowsSpecimen.image(number: 1, width: 400, height: 200)
        let row = AttachmentsRowView()
        let spy = Spy()
        row.delegate = spy
        row.configure(with: .init(images: [image], titles: ["Image 1"], highlighted: nil))
        let thumbnail = try XCTUnwrap(
            row.subviews.first { $0.isAccessibilityElement() && $0.accessibilityRole() == .image })
        XCTAssertEqual(thumbnail.accessibilityLabel(), "Image 1")
        XCTAssertTrue(thumbnail.accessibilityPerformPress())
        XCTAssertEqual(spy.opened, [image.id])
    }
}
