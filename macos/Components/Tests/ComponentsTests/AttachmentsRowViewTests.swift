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
}
