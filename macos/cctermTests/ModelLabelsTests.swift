import AgentSDK
import XCTest

@testable import ccterm

/// Pins the permission-mode and effort labels to their English,
/// CLI-mirroring values. They are deliberately NOT localized — they
/// reference the CLI vocabulary the user is toggling. Translating them
/// obscures what they actually do.
///
/// A regression here would be re-introducing `String(localized:)` for
/// any of these labels, which routes through `Localizable.xcstrings`
/// and switches under `zh-Hans`. The asserts below would still pass
/// under the English fallback but fail under a translated catalog —
/// run the suite at least once with `AppleLanguages = ("zh-Hans")`
/// before relying on the gate.
final class ModelLabelsTests: XCTestCase {

    func testPermissionModeTitlesAreLiteralEnglish() {
        XCTAssertEqual(PermissionMode.default.title, "Ask permissions")
        XCTAssertEqual(PermissionMode.acceptEdits.title, "Accept edits")
        XCTAssertEqual(PermissionMode.plan.title, "Plan mode")
        XCTAssertEqual(PermissionMode.auto.title, "Auto mode")
        XCTAssertEqual(PermissionMode.bypassPermissions.title, "Bypass permissions")
    }

    func testPermissionModeShortTitlesAreLiteralEnglish() {
        XCTAssertEqual(PermissionMode.default.shortTitle, "Ask")
        XCTAssertEqual(PermissionMode.acceptEdits.shortTitle, "Edit")
        XCTAssertEqual(PermissionMode.plan.shortTitle, "Plan")
        XCTAssertEqual(PermissionMode.auto.shortTitle, "Auto")
        XCTAssertEqual(PermissionMode.bypassPermissions.shortTitle, "Bypass")
    }

    func testEffortTitlesAreLiteralEnglish() {
        XCTAssertEqual(Effort.low.title, "Low")
        XCTAssertEqual(Effort.medium.title, "Medium")
        XCTAssertEqual(Effort.high.title, "High")
        XCTAssertEqual(Effort.xhigh.title, "Extra high")
        XCTAssertEqual(Effort.max.title, "Max")
        XCTAssertEqual(Effort.ultracode.title, "Ultracode")
    }
}
