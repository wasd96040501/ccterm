import AppKit
import XCTest

@testable import Components
@testable import ComponentsDesign

/// A picture beside the transcript: centred while it is smaller than the
/// editor, scrolled with its margin while it is larger.
@MainActor
final class ImageDocumentViewControllerTests: XCTestCase {
    private func mount(width: Int, height: Int) -> (NSScrollView, NSImageView) {
        let document = ImageDocumentViewController(
            RowsSpecimen.image(number: 1, width: width, height: height), title: "Image 1")
        document.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        document.view.layoutSubtreeIfNeeded()
        let scroll = document.view.subviews.compactMap { $0 as? NSScrollView }.first!
        let picture = scroll.documentView!.subviews.compactMap { $0 as? NSImageView }.first!
        return (scroll, picture)
    }

    func testASmallPictureIsCentredInTheEditor() {
        let (scroll, picture) = mount(width: 100, height: 50)
        let document = scroll.documentView!
        XCTAssertEqual(document.frame.size, scroll.contentView.bounds.size)
        XCTAssertEqual(picture.frame.midX, document.bounds.midX, accuracy: 0.5)
        XCTAssertEqual(picture.frame.midY, document.bounds.midY, accuracy: 0.5)
    }

    func testALargePictureScrollsWithItsMargin() {
        let (scroll, picture) = mount(width: 1000, height: 800)
        let document = scroll.documentView!
        XCTAssertEqual(document.frame.width, picture.frame.width + 48, accuracy: 0.5)
        XCTAssertEqual(document.frame.height, picture.frame.height + 48, accuracy: 0.5)
        XCTAssertEqual(picture.frame.minX, 24, accuracy: 0.5)
    }
}
