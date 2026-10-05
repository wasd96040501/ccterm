import AppKit
import DisplayModels
import XCTest

@testable import Components

final class StyledTextDrawingTests: XCTestCase {
    func testEachStyleIsDrawnAsTheDesignSays() {
        let text =
            StyledText("Edited ") + StyledText("A.swift", style: .noun(opens: "e1")) + StyledText(" ")
            + StyledText("*.swift", style: .code) + StyledText(" +3", style: .added)
            + StyledText(" −1", style: .removed)
        let font = NSFont.systemFont(ofSize: 13)
        let drawn = text.attributedString(font: font, color: .secondaryLabelColor)
        XCTAssertEqual(drawn.string, text.string)

        func attribute(_ key: NSAttributedString.Key, at substring: String) -> Any? {
            let location = (drawn.string as NSString).range(of: substring).location
            return drawn.attribute(key, at: location, effectiveRange: nil)
        }
        XCTAssertEqual(attribute(.foregroundColor, at: "Edited") as? NSColor, .secondaryLabelColor)
        XCTAssertEqual(attribute(.foregroundColor, at: "A.swift") as? NSColor, .labelColor)
        XCTAssertEqual(attribute(StyledText.opensKey, at: "A.swift") as? String, "e1")
        XCTAssertNil(attribute(StyledText.opensKey, at: "Edited"))
        XCTAssertEqual((attribute(.font, at: "*.swift") as? NSFont)?.pointSize, 12)
        XCTAssertTrue(
            (attribute(.font, at: "*.swift") as? NSFont)?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false)
        XCTAssertEqual(attribute(.foregroundColor, at: "+3") as? NSColor, .addedText)
        XCTAssertEqual(attribute(.foregroundColor, at: "−1") as? NSColor, .failureText)
    }
}
