import AgentSDK
import XCTest

@testable import ccterm

/// The `.ultracode` effort tier is `effortLevel: xhigh` plus the CLI's
/// `ultracode` setting, and every other tier must send `ultracode: false`
/// so the two stay mutually exclusive.
///
/// These tests pin that translation at both boundaries:
/// - mid-session `applySettings` (`Effort.settings`),
/// - session launch (`SessionConfig.toAgentSDKConfig`).
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

    // MARK: - Launch injection — SessionConfig.toAgentSDKConfig

    func testUltracodeConfigLaunchesWithUltracodeSettings() {
        var config = SessionConfig(cwd: "/tmp/ultracode")
        config.effort = .ultracode
        let sdk = config.toAgentSDKConfig(
            sessionId: UUID().uuidString, resume: false, customCommand: nil)

        XCTAssertEqual(sdk.effort, .xhigh)
        XCTAssertEqual(sdk.settings[.ultracode], true)
    }

    func testNormalEffortConfigLaunchesWithoutSettings() {
        var config = SessionConfig(cwd: "/tmp/normal")
        config.effort = .high
        let sdk = config.toAgentSDKConfig(
            sessionId: UUID().uuidString, resume: false, customCommand: nil)

        XCTAssertEqual(sdk.effort, .high)
        XCTAssertTrue(sdk.settings.isEmpty)
    }
}
