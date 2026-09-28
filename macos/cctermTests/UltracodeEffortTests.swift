import AgentSDK
import XCTest

@testable import ccterm

/// The `.ultracode` effort tier is `effortLevel: xhigh` plus the CLI's
/// `ultracode` setting, and every other tier must send `ultracode: false`
/// so the two stay mutually exclusive.
///
/// These tests pin that translation in `Effort.settings`, the payload a
/// session sends when the tier changes.
@MainActor
final class UltracodeEffortTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Effort.settings — the mid-session payload

    func testUltracodeEffortIsXhighPlusUltracode() {
        let settings = Effort.ultracode.settings
        XCTAssertEqual(settings[.effortLevel], .xhigh)
        XCTAssertEqual(settings[.ultracode], true)
    }

    func testNormalEffortTurnsUltracodeOff() {
        let settings = Effort.high.settings
        XCTAssertEqual(settings[.effortLevel], .high)
        XCTAssertEqual(
            settings[.ultracode], false,
            "Picking a normal effort must turn ultracode off so the tiers stay mutually exclusive")
    }
}
