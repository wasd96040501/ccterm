import AgentSDK
import XCTest

@testable import ccterm

/// Cover the `ModelInfo.conciseDisplayName` regex transforms so future
/// CLI shape changes are caught here, not via a regressed picker.
final class ModelInfoDisplayTests: XCTestCase {

    func testStripsRecommendedParenthetical() {
        let info = make(value: "claude-opus-4-7", displayName: "Default (recommended)")
        XCTAssertEqual(info.conciseDisplayName, "Default")
    }

    func testRewritesOneMillionContextSuffix() {
        let info = make(value: "claude-opus-4-7[1m]", displayName: "Opus 4.7 (1M context)")
        XCTAssertEqual(info.conciseDisplayName, "Opus 4.7 1M")
    }

    func testAddsVersionToBareFamilyName() {
        let info = make(value: "claude-sonnet-4-6", displayName: "Sonnet")
        XCTAssertEqual(info.conciseDisplayName, "Sonnet 4.6")
    }

    func testAddsVersionWhenValueHasTrailingDate() {
        let info = make(value: "claude-haiku-4-5-20251001", displayName: "Haiku")
        XCTAssertEqual(info.conciseDisplayName, "Haiku 4.5")
    }

    func testPassesAlreadyConciseNamesThrough() {
        let info = make(value: "claude-opus-4-7", displayName: "Opus 4.7")
        XCTAssertEqual(info.conciseDisplayName, "Opus 4.7")
    }

    /// Future CLI may invent a new shape we haven't seen. Verify the
    /// transform doesn't drop the row — the original `displayName`
    /// survives even when none of the rules match.
    func testUnknownShapeFallsBackToDisplayName() {
        let info = make(
            value: "claude-future-model-id-99",
            displayName: "Future Model Z")
        XCTAssertEqual(info.conciseDisplayName, "Future Model Z")
    }

    /// Edge case: displayName has only marketing parens — after
    /// stripping we'd be left with empty string. Must fall back to
    /// the raw label rather than rendering an empty row.
    func testAllParensFallsBackToOriginal() {
        let info = make(value: "claude-x", displayName: "(beta)")
        XCTAssertEqual(info.conciseDisplayName, "(beta)")
    }

    // MARK: - Helpers

    private func make(value: String, displayName: String) -> ModelInfo {
        let raw: [String: Any] = ["value": value, "displayName": displayName]
        return try! ModelInfo(json: raw)
    }
}
