import AgentSDK
import XCTest

@testable import ccterm

/// Pins the input-bar chrome labels to their English, CLI-mirroring
/// values. Permission-mode names, effort levels, model picker section
/// titles, and the fast-mode toggle label are deliberately NOT
/// localized — they reference the CLI vocabulary the user is toggling.
/// Translating them obscures what they actually do.
///
/// A regression here would be re-introducing `String(localized:)` for
/// any of these labels, which routes through `Localizable.xcstrings`
/// and switches under `zh-Hans`. The asserts below would still pass
/// under the English fallback but fail under a translated catalog —
/// run the suite at least once with `AppleLanguages = ("zh-Hans")`
/// before relying on the gate.
final class InputBarLabelsTests: XCTestCase {

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
        XCTAssertEqual(AgentSDK.Effort.low.title, "Low")
        XCTAssertEqual(AgentSDK.Effort.medium.title, "Medium")
        XCTAssertEqual(AgentSDK.Effort.high.title, "High")
        XCTAssertEqual(AgentSDK.Effort.xhigh.title, "Extra high")
        XCTAssertEqual(AgentSDK.Effort.max.title, "Max")
    }
}
